// Monomorphization Collect Pass — find generic definitions + call sites
//
// Reference implementation equivalent: overload resolution triggering instance generation.
// Our approach: eager two-step scan (definitions, then call sites).

import { Node, NodeKind, NodeData, makeLoc, ProgramData, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData, FunctionDeclData, ArrowFunctionData, FunctionExprData, ClassDeclData, MethodDeclData, ConstructorDeclData, ExportDeclData, DecoratedDeclData, MacroDeclData, VariableDeclData, ReturnStmtData, ThrowStmtData, ExprStmtData, TryCatchStmtData, DeferStmtData, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData, MatchExprData, MatchStmtData, MatchCaseData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, TypeAssertionData, DestructuringDeclData, QuoteExprData, MacroInvocationData, IdentifierData, NumberLiteralData, StringLiteralData, BooleanLiteralData, ImportDeclData, TypeAliasDeclData, EnumDeclData, InterfaceDeclData, PropertyDeclData, ExternDeclData, TypeAnnotationData, BreakStmtData, ContinueStmtData, UnreachableStmtData, BigIntLiteralData, RegexLiteralData, HiddenStdConvData, createNodeAt, Type, TypeKind, Symbol, SymbolKind } from "../ast/node";
import { unknownType, numberType, stringType, booleanType, nullType, createFunction, createArray, unifyType, createUnifyBindings } from "../checker/types";
import { CheckerContext, extractGenericNames, stripGenFlag } from "../checker/context";
import { ScopeKind, lookupSymbol, defineSymbol, makeSymbol, openScope, closeScope } from "../checker/symbol";
import { replaceTypeVars } from "../checker/instantiate";
import { monoCloneNode, monoSubstAnnotation, monoConcreteTypeName } from "./clone";
import { MonoRegistry, MonoEntry, monoRegister, monoFindEntry, buildTypeArgKeys, createMonoRegistry } from "./registry";
import { splitTopLevel, findChar } from "../utils/string";
import {
	getExplicitTypeArg,
	getGenericTypeInstCount, getGenericTypeInstMangledName,
	getGenericTypeInstFieldCount, getGenericTypeInstFieldNameAt,
	getGenericTypeInstFieldTypeAt, resetGenericTypeInsts,
} from "../parser/context";
import { callCheckStmt } from "../checker/checkerCallbacks";

// ===== Generic Declaration Map =====
// Primitives only — no Node fields (DRC workaround #22: cross-module Node in interface
// generates wrong lifecycle hooks).

export interface MonoGenericDeclMap {
	names: string[];             // generic function names
	paramNames: string[];        // comma-joined generic param names ("T,U")
}

export function createMonoGenericDeclMap(): MonoGenericDeclMap {
	const names: string[] = [];
	const paramNames: string[] = [];
	return { names: names, paramNames: paramNames };
}

function monoFindGenericIndex(declMap: MonoGenericDeclMap, name: string): number {
	for (let i = 0; i < declMap.names.length; i += 1) {
		if (declMap.names[i] === name) return i;
	}
	return -1;
}

function monoGetParamNames(declMap: MonoGenericDeclMap, idx: number): string[] {
	if (idx < 0) {
		const empty: string[] = [];
		return empty;
	}
	return splitTopLevel(declMap.paramNames[idx], ",");
}

// ===== Explicit Type Args Resolution =====
// Resolve type arg strings (from parser side-channel) to Type objects.

function monoResolveExplicitTypeArgs(typeArgStr: string): Type[] {
	const result: Type[] = [];
	const parts = splitTopLevel(typeArgStr, ",");
	for (const part of parts) {
		const name = part.trim();
		const resolved = monoResolveTypeName(name);
		if (resolved !== null) result.push(resolved);
	}
	return result;
}

function monoResolveTypeName(name: string): Type {
	const kind = match (name) {
		"number" => TypeKind.Number,
		"string" => TypeKind.String,
		"boolean" => TypeKind.Boolean,
		"void" => TypeKind.Void,
		_ => TypeKind.Struct,
	};
	const tname = kind === TypeKind.Struct ? name : "";
	return { kind, typeName: tname, typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
}

// ===== Resolve Annotation String → Type =====
// Local resolver for monomorphized type annotations. Avoids importing resolvePass
// (DRC safety). Handles primitives, arrays, and named types.

function monoResolveAnnotation(annotation: string): Type {
	const trimmed = annotation.trim();
	if (trimmed === "") return unknownType();
	// Array suffix: number[]
	if (trimmed.length > 2) {
		const suffix = trimmed.slice(trimmed.length - 2, trimmed.length);
		if (suffix === "[]") {
			const inner = trimmed.slice(0, trimmed.length - 2);
			return createArray(monoResolveAnnotation(inner));
		}
	}
	// Token-joined form: number [ ]
	if (trimmed.length > 4) {
		const suffix3 = trimmed.slice(trimmed.length - 3, trimmed.length);
		if (suffix3 === "[ ]") {
			const inner = trimmed.slice(0, trimmed.length - 3).trim();
			return createArray(monoResolveAnnotation(inner));
		}
	}
	// Generic types: Array<X>
	const angleBracket = findChar(trimmed, "<");
	if (angleBracket > 0) {
		const lastChar = trimmed.charAt(trimmed.length - 1);
		if (lastChar === ">") {
			const baseName = trimmed.slice(0, angleBracket).trim();
			const argsText = trimmed.slice(angleBracket + 1, trimmed.length - 1).trim();
			if (baseName === "Array") {
				return createArray(monoResolveAnnotation(argsText));
			}
			// For other generic types, fall back to named type with base name
			return monoResolveTypeName(baseName);
		}
	}
	// Primitives and named types
	return monoResolveTypeName(trimmed);
}

// ===== Body Re-Type-Checking =====
// Run checker Pass 3 on each instantiated FunctionDecl body.
// Uses callCheckStmt callback to avoid direct checkPass import.

function monoCheckInstantiatedBody(ctx: CheckerContext, fnNode: Node): void {
	if (fnNode === null) return;
	if (fnNode.kind !== NodeKind.FunctionDecl) return;
	const d = fnNode.data as FunctionDeclData;

	// Resolve param types from concrete annotation strings
	const paramTypes: Type[] = [];
	for (let pi = 0; pi < d.fnParamTypes.length; pi += 1) {
		if (d.fnParamTypes[pi] !== "") {
			paramTypes.push(monoResolveAnnotation(d.fnParamTypes[pi]));
		} else {
			paramTypes.push(unknownType());
		}
	}

	// Resolve return type
	let retType = unknownType();
	if (d.fnReturnType !== "") {
		retType = monoResolveAnnotation(d.fnReturnType);
	}

	// Create function type + symbol
	const fnType = createFunction(paramTypes, d.params, retType);
	const sym = makeSymbol(d.fnName, SymbolKind.Function, fnType, false);

	// Define in current scope (so recursive references work)
	defineSymbol(ctx.table, sym);

	// Save/restore context state
	const savedFunction = ctx.currentFunction;
	const savedReturn = ctx.inferredReturn;
	ctx.currentFunction = sym;
	ctx.inferredReturn = unknownType();

	// Open scope, define params, check body
	openScope(ctx.table, ScopeKind.Function);
	for (let i = 0; i < d.params.length; i += 1) {
		let paramType = unknownType();
		if (i < paramTypes.length) { paramType = paramTypes[i]; }
		defineSymbol(ctx.table, makeSymbol(d.params[i], SymbolKind.Parameter, paramType, false));
	}

	if (d.fnBody !== null && d.fnBody.kind === NodeKind.BlockStmt) {
		callCheckStmt(ctx, d.fnBody);
	}

	closeScope(ctx.table);

	// Update return type if inferred
	if (retType.kind === TypeKind.Unknown && ctx.inferredReturn.kind !== TypeKind.Unknown) {
		sym.symbolType.typeReturn = ctx.inferredReturn;
	}

	// Restore context
	ctx.currentFunction = savedFunction;
	ctx.inferredReturn = savedReturn;
}

// ===== Pass 1a: Collect Generic Definitions =====

export function monoCollectDefinitions(program: Node, declMap: MonoGenericDeclMap): void {
	if (program === null) return;
	if (program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		monoCollectDefStmt(stmt, declMap);
	}
}

// Join string array with comma — extracted to avoid DRC msDecref bug on let-string in try/finally
function joinWithComma(parts: string[]): string {
	if (parts.length === 0) return "";
	let result = parts[0];
	for (let i = 1; i < parts.length; i += 1) {
		result = result + "," + parts[i];
	}
	return result;
}

function monoCollectDefStmt(node: Node, declMap: MonoGenericDeclMap): void {
	if (node === null) return;
	if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		const genNames = extractGenericNames(d.fnFlags);
		if (genNames.length > 0) {
			declMap.names.push(d.fnName);
			const joined = joinWithComma(genNames);
			declMap.paramNames.push(joined);
		}
	}
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		monoCollectDefStmt(d.exportedDecl, declMap);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		monoCollectDefStmt(d.decoratedNode, declMap);
	}
}

// ===== Shared AST Walker =====
// Unified recursive walk using if-else (not match — DRC workaround #24).
// CallExpr nodes are dispatched to the provided handler; all other nodes
// are traversed structurally. Used by both collection and rewrite passes.

type MonoCallHandler = (node: Node, declMap: MonoGenericDeclMap, registry: MonoRegistry, ctx: CheckerContext) => void;

function monoWalkAST(
	node: Node,
	declMap: MonoGenericDeclMap,
	registry: MonoRegistry,
	ctx: CheckerContext,
	handler: MonoCallHandler
): void {
	if (node === null) return;
	const kind = node.kind;

	if (kind === NodeKind.CallExpr) {
		handler(node, declMap, registry, ctx);
		const d = node.data as CallExprData;
		monoWalkAST(d.callee, declMap, registry, ctx, handler);
		for (const arg of d.arguments) {
			monoWalkAST(arg, declMap, registry, ctx, handler);
		}
		return;
	}
	if (kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		for (const s of d.programStmts) { monoWalkAST(s, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const s of d.statements) { monoWalkAST(s, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		monoWalkAST(d.fnBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		monoWalkAST(d.arrowBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		monoWalkAST(d.funcExprBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		monoWalkAST(d.condition, declMap, registry, ctx, handler);
		monoWalkAST(d.consequent, declMap, registry, ctx, handler);
		monoWalkAST(d.alternate, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		monoWalkAST(d.whileCondition, declMap, registry, ctx, handler);
		monoWalkAST(d.whileBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		monoWalkAST(d.forInit, declMap, registry, ctx, handler);
		monoWalkAST(d.forCondition, declMap, registry, ctx, handler);
		monoWalkAST(d.forUpdate, declMap, registry, ctx, handler);
		monoWalkAST(d.forBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		monoWalkAST(d.forOfIterable, declMap, registry, ctx, handler);
		monoWalkAST(d.forOfBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		monoWalkAST(d.forInObject, declMap, registry, ctx, handler);
		monoWalkAST(d.forInBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		monoWalkAST(d.doBody, declMap, registry, ctx, handler);
		monoWalkAST(d.doCondition, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		monoWalkAST(d.argument, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		monoWalkAST(d.expr, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		monoWalkAST(d.initializer, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		monoWalkAST(d.left, declMap, registry, ctx, handler);
		monoWalkAST(d.right, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		monoWalkAST(d.operand, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		monoWalkAST(d.ternaryCondition, declMap, registry, ctx, handler);
		monoWalkAST(d.ternaryConsequent, declMap, registry, ctx, handler);
		monoWalkAST(d.ternaryAlternate, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		monoWalkAST(d.object, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		monoWalkAST(d.array, declMap, registry, ctx, handler);
		monoWalkAST(d.index, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		for (const p of d.properties) { monoWalkAST(p, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		for (const e of d.elements) { monoWalkAST(e, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		monoWalkAST(d.tryBody, declMap, registry, ctx, handler);
		monoWalkAST(d.catchBody, declMap, registry, ctx, handler);
		monoWalkAST(d.finallyBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ThrowStmt) {
		const d = node.data as ThrowStmtData;
		monoWalkAST(d.throwArg, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		monoWalkAST(d.exportedDecl, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		monoWalkAST(d.decoratedNode, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		monoWalkAST(d.switchDisc, declMap, registry, ctx, handler);
		for (const c of d.switchCases) { monoWalkAST(c, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		for (const s of d.caseStmts) { monoWalkAST(s, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		monoWalkAST(d.matchStmtDisc, declMap, registry, ctx, handler);
		for (const c of d.matchStmtCases) { monoWalkAST(c, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		monoWalkAST(d.matchDisc, declMap, registry, ctx, handler);
		for (const c of d.matchCases) { monoWalkAST(c, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.MatchCase) {
		const d = node.data as MatchCaseData;
		monoWalkAST(d.caseBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.SpreadExpr) {
		const d = node.data as SpreadExprData;
		monoWalkAST(d.spreadArg, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		monoWalkAST(d.newCallee, declMap, registry, ctx, handler);
		for (const a of d.newArguments) { monoWalkAST(a, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.TryExpr) {
		const d = node.data as TryExprData;
		monoWalkAST(d.tryArg, declMap, registry, ctx, handler);
		if (d.hasCatch) { monoWalkAST(d.catchVal, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		for (const m of d.classBody) { monoWalkAST(m, declMap, registry, ctx, handler); }
		return;
	}
	if (kind === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		monoWalkAST(d.methodBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		monoWalkAST(d.ctorBody, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		monoWalkAST(d.asExpr, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		monoWalkAST(d.updateArg, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.DestructuringDecl) {
		const d = node.data as DestructuringDeclData;
		monoWalkAST(d.destrPattern, declMap, registry, ctx, handler);
		monoWalkAST(d.destrInit, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.DeferStmt) {
		const d = node.data as DeferStmtData;
		monoWalkAST(d.deferExpr, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		monoWalkAST(d.awaitArg, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.YieldExpr) {
		const d = node.data as YieldExprData;
		monoWalkAST(d.yieldArg, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) {
		const d = node.data as ExprStmtData;
		monoWalkAST(d.expr, declMap, registry, ctx, handler);
		return;
	}
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) {
		const d = node.data as HiddenStdConvData;
		monoWalkAST(d.convExpr, declMap, registry, ctx, handler);
		return;
	}
	// Leaf nodes (Identifier, literals, break, continue, etc.): no children to walk
}

// ===== Pass 1b: Collect Call Sites =====
// Walk entire AST to find CallExpr nodes that call generic functions.
// For each, infer concrete type args from the checker's symbol table.

export function monoCollectCallSites(
	program: Node,
	declMap: MonoGenericDeclMap,
	registry: MonoRegistry,
	checkerCtx: CheckerContext
): void {
	if (program === null) return;
	monoWalkAST(program, declMap, registry, checkerCtx, monoProcessCallExpr);
}

// ===== Process a CallExpr =====
// Check if callee is a generic function; if so, infer type args and register.

function monoProcessCallExpr(
	node: Node,
	declMap: MonoGenericDeclMap,
	registry: MonoRegistry,
	ctx: CheckerContext
): void {
	const d = node.data as CallExprData;

	// Get callee name (simple identifiers only for now)
	if (d.callee === null) return;
	if (d.callee.kind !== NodeKind.Identifier) return;
	// Skip call sites already handled by on-demand instantiation (generateInstance parity)
	if (node.resolvedSym !== null && node.resolvedSym.name.indexOf("__") > 0) return;
	const calleeName = (d.callee.data as IdentifierData).name;

	// Look up in generic declarations
	const genIdx = monoFindGenericIndex(declMap, calleeName);
	if (genIdx < 0) return;

	// Look up function type in symbol table to get formal param types
	const sym = lookupSymbol(ctx.table, calleeName);
	if (sym === null) return;
	if (sym.symbolType === null) return;
	if (sym.symbolType.kind !== TypeKind.Function) return;

	// Check for explicit type args from parser side-channel (keyed by call site location)
	const explicitStr = getExplicitTypeArg(node.location.line, node.location.column);

	// Resolve type args: explicit if provided, otherwise infer from arguments
	let concreteTypes: Type[] = [];
	if (explicitStr !== "") {
		concreteTypes = monoResolveExplicitTypeArgs(explicitStr);
	} else {
		concreteTypes = monoInferTypeArgs(sym.symbolType, d.arguments, ctx);
	}
	if (concreteTypes.length === 0) return;

	// Register this instantiation
	const paramNames = monoGetParamNames(declMap, genIdx);
	monoRegister(registry, calleeName, paramNames, concreteTypes);
}

// ===== Type Arg Inference =====
// Match GenericParam formal params against concrete argument types.
// Uses unifyType for recursive structural matching (handles Array<T>, Result<T,E>, etc.).
// Mirrors checkExprPass.ms:inferGenericReturn but returns concrete type args for monomorphization.

function monoInferTypeArgs(fnType: Type, argNodes: Node[], ctx: CheckerContext): Type[] {
	const bindings = createUnifyBindings();

	for (let i = 0; i < fnType.typeChildren.length && i < argNodes.length; i += 1) {
		const argType = monoInferArgType(argNodes[i], ctx);
		if (argType !== null && argType.kind !== TypeKind.Unknown && argType.kind !== TypeKind.Error) {
			unifyType(fnType.typeChildren[i], argType, bindings);
		}
	}
	// Deduplicate: keep first binding for each unique generic param name
	const result: Type[] = [];
	const seenNames: string[] = [];
	for (let bi = 0; bi < bindings.names.length; bi += 1) {
		let found = false;
		for (let si = 0; si < seenNames.length; si += 1) {
			if (seenNames[si] === bindings.names[bi]) { found = true; }
		}
		if (!found) {
			seenNames.push(bindings.names[bi]);
			result.push(bindings.types[bi]);
		}
	}
	return result;
}

// Infer the type of an argument expression from the checker's perspective.
// Simple cases: number/string/boolean literals, identifiers with known types.
function monoInferArgType(node: Node, ctx: CheckerContext): Type {
	if (node === null) return null;

	if (node.kind === NodeKind.NumberLiteral) return numberType();
	if (node.kind === NodeKind.StringLiteral) return stringType();
	if (node.kind === NodeKind.BooleanLiteral) return booleanType();
	if (node.kind === NodeKind.NullLiteral) return nullType();

	// Identifier: look up in symbol table
	if (node.kind === NodeKind.Identifier) {
		const name = (node.data as IdentifierData).name;
		const sym = lookupSymbol(ctx.table, name);
		if (sym !== null) return sym.symbolType;
	}

	// ArrayLiteral: infer from first element
	if (node.kind === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		if (d.elements.length > 0) {
			const elemType = monoInferArgType(d.elements[0], ctx);
			if (elemType !== null) return createArray(elemType);
		}
	}

	// For CallExpr: check return type of callee
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		if (cd.callee !== null && cd.callee.kind === NodeKind.Identifier) {
			const calleeName = (cd.callee.data as IdentifierData).name;
			const sym = lookupSymbol(ctx.table, calleeName);
			if (sym !== null && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Function) {
				return sym.symbolType.typeReturn;
			}
		}
	}

	return null;
}

// Rewrite a single CallExpr — replace callee with monomorphized name.
// Skip call sites already handled by on-demand instantiation (generateInstance parity):
// the checker sets resolvedSym to the instantiated symbol, so monomorphize must not
// overwrite the callee name with a different (module-qualified) mangling.
function monoRewriteCallExpr(
	node: Node,
	declMap: MonoGenericDeclMap,
	registry: MonoRegistry,
	ctx: CheckerContext
): void {
	const d = node.data as CallExprData;
	if (d.callee === null) return;
	if (d.callee.kind !== NodeKind.Identifier) return;
	// On-demand instantiation already handled — resolvedSym points to instantiated symbol
	if (node.resolvedSym !== null && node.resolvedSym.name.indexOf("__") > 0) return;

	const calleeName = (d.callee.data as IdentifierData).name;

	// Check if this calls a generic function
	const genIdx = monoFindGenericIndex(declMap, calleeName);
	if (genIdx < 0) return;

	// Look up function type for arg type inference
	const sym = lookupSymbol(ctx.table, calleeName);
	if (sym === null) return;
	if (sym.symbolType === null) return;
	if (sym.symbolType.kind !== TypeKind.Function) return;

	// Check for explicit type args from parser side-channel
	const explicitStr = getExplicitTypeArg(node.location.line, node.location.column);

	// Resolve type args: explicit if provided, otherwise infer
	let concreteTypes: Type[] = [];
	if (explicitStr !== "") {
		concreteTypes = monoResolveExplicitTypeArgs(explicitStr);
	} else {
		concreteTypes = monoInferTypeArgs(sym.symbolType, d.arguments, ctx);
	}
	if (concreteTypes.length === 0) return;

	// Find registry entry
	const typeArgKeys = buildTypeArgKeys(concreteTypes);
	const entry = monoFindEntry(registry, calleeName, typeArgKeys);
	if (entry === null) return;

	// Rewrite callee name in-place.
	// Clear resolvedSym so codegen uses the rewritten identifier name directly,
	// not the original generic symbol's module-qualified name.
	const calleeId = d.callee.data as IdentifierData;
	calleeId.name = entry.mangledName;
	node.resolvedSym = null as unknown as Symbol;
	d.callee.resolvedSym = null as unknown as Symbol;
}


// Type-to-string for C naming. MUST match codegen typeKey format (types.ms:179-268)
// so constructor type names and codegen type names are identical.
export function monoTypeKey(t: Type): string {
	if (t === null) return "unknown";
	return match (t.kind) {
		TypeKind.Number => "number",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Ref => "ref:" + monoTypeKey(t.typeReturn),
		TypeKind.Ptr => "ptr:" + monoTypeKey(t.typeReturn),
		TypeKind.Array => "array:" + monoTypeKey(t.typeReturn),
		TypeKind.Struct => "object:" + t.typeName,
		TypeKind.Enum => "enum:" + t.typeName,
		TypeKind.GenericInstance => {
			let name = "ginst:" + t.typeName;
			let i = 0;
			while (i < t.typeChildren.length) {
				name = name + ":" + monoTypeKey(t.typeChildren[i]);
				i = i + 1;
			}
			return name;
		},
		TypeKind.Union => t.typeName !== "" ? "union:" + t.typeName : "union",
		TypeKind.Function => "function",
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.Char => "char",
		TypeKind.CString => "cstring",
		_ => "unknown",
	};
}

function monoFindFnDeclByName(program: Node, fnName: string): Node {
	if (program === null) return null as unknown as Node;
	if (program.kind !== NodeKind.Program) return null as unknown as Node;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const found = monoFindFnDeclInStmt(pd.programStmts[i], fnName);
		if (found !== null) return found;
	}
	return null as unknown as Node;
}

function monoFindFnDeclInStmt(node: Node, fnName: string): Node {
	if (node === null) return null as unknown as Node;
	if (node.kind === NodeKind.FunctionDecl) { const d = node.data as FunctionDeclData; if (d.fnName === fnName) return node; }
	if (node.kind === NodeKind.ExportDecl) { const d = node.data as ExportDeclData; return monoFindFnDeclInStmt(d.exportedDecl, fnName); }
	if (node.kind === NodeKind.DecoratedDecl) { const d = node.data as DecoratedDeclData; return monoFindFnDeclInStmt(d.decoratedNode, fnName); }
	return null as unknown as Node;
}

// Instantiate one entry: clone + substitute. Returns the cloned node or null.
function monoInstantiateEntry(program: Node, entry: MonoEntry): Node {
	const original = monoFindFnDeclByName(program, entry.genericName);
	if (original === null) return null as unknown as Node;
	const cloned = monoCloneNode(original);
	if (cloned === null) return null as unknown as Node;
	monoApplySubstitutions(cloned, entry);
	entry.isInstantiated = true;
	return cloned;
}

// Fixed-point instantiation loop (reference: reference instantiation:377, max 50 iterations).
// After cloning each entry, re-scan its body for nested generic calls and register them.
// Repeat until no new entries appear.
function monoInstantiateAllFixedPoint(
	program: Node,
	registry: MonoRegistry,
	declMap: MonoGenericDeclMap,
	ctx: CheckerContext
): Node[] {
	const generated: Node[] = [];
	let iteration = 0;
	let prevCount = 0;
	let keepGoing = true;
	while (keepGoing && iteration < 50) {
		let foundNew = false;
		for (let i = 0; i < registry.entries.length; i += 1) {
			const entry = registry.entries[i];
			if (!entry.isInstantiated) {
				const cloned = monoInstantiateEntry(program, entry);
				if (cloned !== null) {
					generated.push(cloned);
					// Scan cloned body for nested generic calls
					monoWalkAST(cloned, declMap, registry, ctx, monoProcessCallExpr);
				}
			}
		}
		if (registry.entries.length === prevCount) { keepGoing = false; }
		else { prevCount = registry.entries.length; }
		iteration += 1;
	}
	return generated;
}

function monoApplySubstitutions(fnNode: Node, entry: MonoEntry): void {
	if (fnNode.kind !== NodeKind.FunctionDecl) return;
	const d = fnNode.data as FunctionDeclData;
	d.fnName = entry.mangledName;
	d.fnFlags = stripGenFlag(d.fnFlags);
	for (let pi = 0; pi < entry.genericParamNames.length && pi < entry.concreteTypes.length; pi += 1) {
		const paramName = entry.genericParamNames[pi];
		const concreteName = monoConcreteTypeName(entry.concreteTypes[pi]);
		for (let ti = 0; ti < d.fnParamTypes.length; ti += 1) { d.fnParamTypes[ti] = monoSubstAnnotation(d.fnParamTypes[ti], paramName, concreteName); }
		d.fnReturnType = monoSubstAnnotation(d.fnReturnType, paramName, concreteName);
	}
	// Substitute type params in body VarDecl.declType and nodeType.
	// Without this, locals like `const result: T[] = []` keep unresolved type params,
	// causing the DRC inject to miss array cleanup (nodeType stays null).
	// Parity: instantiateGenericFunction calls replaceTypeVars on the body.
	if (d.fnBody !== null) {
		replaceTypeVars(d.fnBody, entry.genericParamNames, entry.concreteTypes);
	}
}

// ===== Generic Type Instance → InterfaceDecl Nodes =====
// Standard-aligned: monomorphize creates concrete InterfaceDecl nodes so codegen
// is fully generic-unaware. Reads from GenericTypeInstStore (populated by checker).

function monoEmitOneTypeInst(program: Node, idx: number): void {
	const mangledName = getGenericTypeInstMangledName(idx);
	const fieldCount = getGenericTypeInstFieldCount(idx);
	const fieldNames: string[] = [];
	const fieldTypes: string[] = [];
	for (let fi = 0; fi < fieldCount; fi += 1) {
		fieldNames.push(getGenericTypeInstFieldNameAt(idx, fi));
		fieldTypes.push(getGenericTypeInstFieldTypeAt(idx, fi));
	}
	const loc = makeLoc(0, 0);
	const data: NodeData = { interfaceName: mangledName, interfaceFields: fieldNames, interfaceFieldTypes: fieldTypes, nameLocation: loc };
	const declNode = createNodeAt(NodeKind.InterfaceDecl, data, loc);
	const pd = program.data as ProgramData;
	pd.programStmts.push(declNode);
}

function monoEmitTypeInstNodes(program: Node): void {
	const count = getGenericTypeInstCount();
	for (let i = 0; i < count; i += 1) {
		monoEmitOneTypeInst(program, i);
	}
	resetGenericTypeInsts();
}

// ===== Public Entry Point =====

export function monomorphizeProgram(program: Node, checkerCtx: CheckerContext): Node {
	if (checkerCtx === null) return program;
	if (program === null) return program;
	if (program.kind !== NodeKind.Program) return program;

	// Phase 1: Create InterfaceDecl nodes for generic type instantiations
	// (independent of function monomorphization — Box<number> may exist without generic functions)
	// Class constructors are handled separately via on-demand instantiation in checkExprPass.
	monoEmitTypeInstNodes(program);

	const pd = program.data as ProgramData;

	// Phase 2: Monomorphize generic functions (user-defined only)
	// Prelude generics are handled by on-demand instantiation in checkExprPass.ms
	const declMap = createMonoGenericDeclMap();
	monoCollectDefinitions(program, declMap);
	if (declMap.names.length === 0) return program;
	const registry = createMonoRegistry();
	monoCollectCallSites(program, declMap, registry, checkerCtx);
	if (registry.entries.length === 0) return program;
	const generatedNodes = monoInstantiateAllFixedPoint(program, registry, declMap, checkerCtx);

	// Re-type-check instantiated bodies (before rewrite — callee names are still original)
	for (const gn of generatedNodes) {
		monoCheckInstantiatedBody(checkerCtx, gn);
	}

	// Rewrite original program + generated nodes (mangle callee names)
	monoWalkAST(program, declMap, registry, checkerCtx, monoRewriteCallExpr);
	for (const gn of generatedNodes) {
		monoWalkAST(gn, declMap, registry, checkerCtx, monoRewriteCallExpr);
	}

	for (const gn of generatedNodes) { pd.programStmts.push(gn); }
	return program;
}

// ===== Tests =====
test "resolveTypeName number" {
	const t = monoResolveTypeName("number");
	assert t.kind === TypeKind.Number;
}

test "resolveTypeName string" {
	const t = monoResolveTypeName("string");
	assert t.kind === TypeKind.String;
}

test "resolveTypeName named" {
	const t = monoResolveTypeName("MyInterface");
	assert t.kind === TypeKind.Struct;
	assert t.typeName === "MyInterface";
}

test "resolveExplicitTypeArgs" {
	const types = monoResolveExplicitTypeArgs("number,string");
	assert types.length === 2;
	assert types[0].kind === TypeKind.Number;
	assert types[1].kind === TypeKind.String;
}

test "resolveAnnotation primitives" {
	assert monoResolveAnnotation("number").kind === TypeKind.Number;
	assert monoResolveAnnotation("string").kind === TypeKind.String;
	assert monoResolveAnnotation("boolean").kind === TypeKind.Boolean;
	assert monoResolveAnnotation("void").kind === TypeKind.Void;
}

test "resolveAnnotation array suffix" {
	const arrType = monoResolveAnnotation("number[]");
	assert arrType.kind === TypeKind.Array;
	assert arrType.typeReturn.kind === TypeKind.Number;
}

test "resolveAnnotation Array generic" {
	const arrType = monoResolveAnnotation("Array<string>");
	assert arrType.kind === TypeKind.Array;
	assert arrType.typeReturn.kind === TypeKind.String;
}

test "resolveAnnotation named type" {
	const t = monoResolveAnnotation("MyInterface");
	assert t.kind === TypeKind.Struct;
	assert t.typeName === "MyInterface";
}

test "resolveAnnotation empty" { assert monoResolveAnnotation("").kind === TypeKind.Unknown; }
