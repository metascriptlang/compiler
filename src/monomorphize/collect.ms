// Monomorphization Collect Pass — find generic definitions + call sites
//
// Reference implementation equivalent: overload resolution triggering instance generation.
// Our approach: eager two-step scan (definitions, then call sites).

import { Node, NodeKind, NodeData, DeclKind, SourceLocation, makeLoc, ProgramData, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData, FunctionDeclData, ArrowFunctionData, FunctionExprData, ClassDeclData, MethodDeclData, ConstructorDeclData, ExportDeclData, DecoratedDeclData, MacroDeclData, VariableDeclData, ReturnStmtData, ThrowStmtData, ExprStmtData, TryCatchStmtData, DeferStmtData, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData, MatchExprData, MatchStmtData, MatchCaseData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, TypeAssertionData, DestructuringDeclData, QuoteExprData, MacroInvocationData, IdentifierData, NumberLiteralData, StringLiteralData, BooleanLiteralData, ImportDeclData, TypeAliasDeclData, EnumDeclData, InterfaceDeclData, PropertyDeclData, ExternDeclData, TypeAnnotationData, BreakStmtData, ContinueStmtData, UnreachableStmtData, BigIntLiteralData, RegexLiteralData, HiddenStdConvData, createNodeAt, Type, TypeKind, Symbol, SymbolKind } from "../ast/node";
import { unknownType, numberType, stringType, booleanType, nullType, createFunction, createArray, unifyType, createUnifyBindings, isResult, getResultOkType, getResultErrType } from "../checker/types";
import { CheckerContext, extractGenericNames, stripGenFlag } from "../checker/context";
import { SymbolTable, ScopeKind, SymbolFlag, lookupSymbol, defineSymbol, makeSymbol, hasFlag, openScope, closeScope } from "../checker/symbol";
import { MonoRegistry, MonoEntry, monoRegister, monoFindEntry, buildTypeArgKeys, monoTypeKey, createMonoRegistry } from "./registry";
import { splitTopLevel, findChar } from "../utils/string";
import {
	getExplicitTypeArg, getGenericDecl,
	getGenericTypeInstCount, getGenericTypeInstMangledName, getGenericTypeInstBaseName, getGenericTypeInstTypeArgKey,
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

// ===== Clone — deep AST copy =====

function cloneNodeArray(nodes: Node[]): Node[] {
	const result: Node[] = [];
	for (const n of nodes) { result.push(monoCloneNode(n)); }
	return result;
}

function cloneStringArray(strs: string[]): string[] {
	const result: string[] = [];
	for (const s of strs) { result.push(s); }
	return result;
}

// Copy node-level metadata from source to clone (copyTree parity: preserves typ, flags).
// nodeType and flags survive cloning so downstream passes have type info.
// resolvedSym is NOT copied — monomorphize relies on name rewriting (not sym refs),
// and on-demand instantiation re-resolves via checkFunctionBody + shared IdentCache.
// Copying resolvedSym would cause monomorphized functions to use the generic symbol's
// name in mangledFunctionName instead of the rewritten mangled name.
function copyNodeMeta(src: Node, dst: Node): Node {
	dst.nodeType = src.nodeType;
	dst.flags = src.flags;
	return dst;
}

export function monoCloneNode(node: Node): Node {
	if (node === null) return null as unknown as Node;
	const loc = makeLoc(node.location.line, node.location.column);
	const kind = node.kind;

	if (kind === NodeKind.NumberLiteral) { const d = node.data as NumberLiteralData; const data: NodeData = { value: d.value, isFloat: d.isFloat }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.StringLiteral) { const d = node.data as StringLiteralData; return copyNodeMeta(node, createNodeAt(kind, { value: d.value } as NodeData, loc)); }
	if (kind === NodeKind.BooleanLiteral) { const d = node.data as BooleanLiteralData; const data: NodeData = { boolValue: d.boolValue }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.NullLiteral) { const data: NodeData = { nullPlaceholder: true }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.BigIntLiteral) { const d = node.data as BigIntLiteralData; const data: NodeData = { bigintValue: d.bigintValue }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.RegexLiteral) { const d = node.data as RegexLiteralData; const data: NodeData = { regexPattern: d.regexPattern }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.Identifier) { const d = node.data as IdentifierData; const data: NodeData = { name: d.name }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.BinaryExpr) { const d = node.data as BinaryExprData; const data: NodeData = { operator: d.operator, left: monoCloneNode(d.left), right: monoCloneNode(d.right) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.UnaryExpr) { const d = node.data as UnaryExprData; const data: NodeData = { unaryOp: d.unaryOp, operand: monoCloneNode(d.operand) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.UpdateExpr) { const d = node.data as UpdateExprData; const data: NodeData = { updateOp: d.updateOp, updateArg: monoCloneNode(d.updateArg), isPrefix: d.isPrefix }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.CallExpr) { const d = node.data as CallExprData; const data: NodeData = { callee: monoCloneNode(d.callee), arguments: cloneNodeArray(d.arguments), isDirectCall: d.isDirectCall, resolvedOverloadIdx: d.resolvedOverloadIdx }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MemberExpr) { const d = node.data as MemberExprData; const data: NodeData = { object: monoCloneNode(d.object), property: d.property, isOptional: d.isOptional }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ArrayAccess) { const d = node.data as ArrayAccessData; const data: NodeData = { array: monoCloneNode(d.array), index: monoCloneNode(d.index) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ObjectLiteral) { const d = node.data as ObjectLiteralData; const data: NodeData = { properties: cloneNodeArray(d.properties), keys: cloneStringArray(d.keys), keyLocations: d.keyLocations !== null ? d.keyLocations : [] }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ArrayLiteral) { const d = node.data as ArrayLiteralData; const data: NodeData = { elements: cloneNodeArray(d.elements) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ArrowFunction) { const d = node.data as ArrowFunctionData; const data: NodeData = { arrowParams: cloneStringArray(d.arrowParams), arrowParamTypes: cloneStringArray(d.arrowParamTypes), arrowBody: monoCloneNode(d.arrowBody), arrowFlags: d.arrowFlags, arrowReturnType: d.arrowReturnType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.FunctionExpr) { const d = node.data as FunctionExprData; const data: NodeData = { funcExprParams: cloneStringArray(d.funcExprParams), funcExprParamTypes: cloneStringArray(d.funcExprParamTypes), funcExprBody: monoCloneNode(d.funcExprBody), funcExprFlags: d.funcExprFlags, funcExprReturnType: d.funcExprReturnType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TypeAssertion) { const d = node.data as TypeAssertionData; const data: NodeData = { asExpr: monoCloneNode(d.asExpr), asType: d.asType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ConditionalExpr) { const d = node.data as ConditionalExprData; const data: NodeData = { ternaryCondition: monoCloneNode(d.ternaryCondition), ternaryConsequent: monoCloneNode(d.ternaryConsequent), ternaryAlternate: monoCloneNode(d.ternaryAlternate) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.SpreadExpr) { const d = node.data as SpreadExprData; const data: NodeData = { spreadArg: monoCloneNode(d.spreadArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.NewExpr) { const d = node.data as NewExprData; const data: NodeData = { newCallee: monoCloneNode(d.newCallee), newArguments: cloneNodeArray(d.newArguments) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TryExpr) { const d = node.data as TryExprData; const data: NodeData = { tryArg: monoCloneNode(d.tryArg), hasCatch: d.hasCatch, catchVal: d.hasCatch ? monoCloneNode(d.catchVal) : null as unknown as Node }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MatchExpr) { const d = node.data as MatchExprData; const data: NodeData = { matchDisc: monoCloneNode(d.matchDisc), matchCases: cloneNodeArray(d.matchCases) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MatchCase) { const d = node.data as MatchCaseData; const data: NodeData = { casePatterns: cloneNodeArray(d.casePatterns), caseBody: monoCloneNode(d.caseBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.AwaitExpr) { const d = node.data as AwaitExprData; const data: NodeData = { awaitArg: monoCloneNode(d.awaitArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.YieldExpr) { const d = node.data as YieldExprData; const data: NodeData = { yieldArg: monoCloneNode(d.yieldArg), isDelegate: d.isDelegate }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MoveExpr) { const d = node.data as MoveExprData; const data: NodeData = { moveArg: monoCloneNode(d.moveArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.OutExpr) { const d = node.data as OutExprData; const data: NodeData = { outArg: monoCloneNode(d.outArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.SizeofExpr) { const d = node.data as SizeofExprData; const data: NodeData = { sizeofType: d.sizeofType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) { const d = node.data as ExprStmtData; const data: NodeData = { expr: monoCloneNode(d.expr) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) { const d = node.data as HiddenStdConvData; const data: NodeData = { convExpr: monoCloneNode(d.convExpr), convType: d.convType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TypeAnnotation) { const d = node.data as TypeAnnotationData; const data: NodeData = { annotationType: d.annotationType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.DestructuringDecl) { const d = node.data as DestructuringDeclData; const data: NodeData = { destrPattern: monoCloneNode(d.destrPattern), destrInit: monoCloneNode(d.destrInit), destrIsConst: d.destrIsConst }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.VariableDecl) { const d = node.data as VariableDeclData; const data: NodeData = { declName: d.declName, declType: d.declType, initializer: monoCloneNode(d.initializer), declKind: d.declKind, nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.IfStmt) { const d = node.data as IfStmtData; const data: NodeData = { condition: monoCloneNode(d.condition), consequent: monoCloneNode(d.consequent), alternate: monoCloneNode(d.alternate) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.WhileStmt) { const d = node.data as WhileStmtData; const data: NodeData = { whileCondition: monoCloneNode(d.whileCondition), whileBody: monoCloneNode(d.whileBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ForStmt) { const d = node.data as ForStmtData; const data: NodeData = { forInit: monoCloneNode(d.forInit), forCondition: monoCloneNode(d.forCondition), forUpdate: monoCloneNode(d.forUpdate), forBody: monoCloneNode(d.forBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ForOfStmt) { const d = node.data as ForOfStmtData; const data: NodeData = { forOfBinding: d.forOfBinding, forOfIsConst: d.forOfIsConst, forOfIterable: monoCloneNode(d.forOfIterable), forOfBody: monoCloneNode(d.forOfBody), forOfPattern: d.forOfPattern !== null ? monoCloneNode(d.forOfPattern) : null as unknown as Node, bindingLocation: d.bindingLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ForInStmt) { const d = node.data as ForInStmtData; const data: NodeData = { forInBinding: d.forInBinding, forInIsConst: d.forInIsConst, forInObject: monoCloneNode(d.forInObject), forInBody: monoCloneNode(d.forInBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.DoWhileStmt) { const d = node.data as DoWhileStmtData; const data: NodeData = { doBody: monoCloneNode(d.doBody), doCondition: monoCloneNode(d.doCondition) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.BlockStmt) { const d = node.data as BlockStmtData; const data: NodeData = { statements: cloneNodeArray(d.statements) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ExprStmt) { const d = node.data as ExprStmtData; const data: NodeData = { expr: monoCloneNode(d.expr) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ReturnStmt) { const d = node.data as ReturnStmtData; const data: NodeData = { argument: monoCloneNode(d.argument) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.BreakStmt) { const d = node.data as BreakStmtData; const data: NodeData = { breakLabel: d.breakLabel }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ContinueStmt) { const d = node.data as ContinueStmtData; const data: NodeData = { continueLabel: d.continueLabel }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.UnreachableStmt) { const d = node.data as UnreachableStmtData; const data: NodeData = { unreachableMsg: d.unreachableMsg }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.FunctionDecl) { const d = node.data as FunctionDeclData; const data: NodeData = { fnName: d.fnName, params: cloneStringArray(d.params), fnParamTypes: cloneStringArray(d.fnParamTypes), fnBody: monoCloneNode(d.fnBody), fnFlags: d.fnFlags, fnReturnType: d.fnReturnType, fnDefaults: cloneNodeArray(d.fnDefaults), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.SwitchStmt) { const d = node.data as SwitchStmtData; const data: NodeData = { switchDisc: monoCloneNode(d.switchDisc), switchCases: cloneNodeArray(d.switchCases) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.SwitchCase) { const d = node.data as SwitchCaseData; const data: NodeData = { caseTests: cloneNodeArray(d.caseTests), caseStmts: cloneNodeArray(d.caseStmts), isDefault: d.isDefault }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MatchStmt) { const d = node.data as MatchStmtData; const data: NodeData = { matchStmtDisc: monoCloneNode(d.matchStmtDisc), matchStmtCases: cloneNodeArray(d.matchStmtCases) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ImportDecl) { const d = node.data as ImportDeclData; const data: NodeData = { importNames: cloneStringArray(d.importNames), importAliases: cloneStringArray(d.importAliases), importSource: d.importSource, nameLocations: d.nameLocations !== null ? d.nameLocations : [] }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ExportDecl) { const d = node.data as ExportDeclData; const data: NodeData = { exportedDecl: monoCloneNode(d.exportedDecl) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TypeAliasDecl) { const d = node.data as TypeAliasDeclData; const data: NodeData = { aliasName: d.aliasName, aliasType: d.aliasType, aliasIsDistinct: d.aliasIsDistinct, discriminantName: d.discriminantName, discriminantType: d.discriminantType, variantKeys: cloneStringArray(d.variantKeys), variantTypes: cloneStringArray(d.variantTypes), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.EnumDecl) { const d = node.data as EnumDeclData; const data: NodeData = { enumName: d.enumName, enumMembers: cloneStringArray(d.enumMembers), nameLocation: d.nameLocation, memberLocations: d.memberLocations !== null ? d.memberLocations : [] }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.InterfaceDecl) { const d = node.data as InterfaceDeclData; const data: NodeData = { interfaceName: d.interfaceName, interfaceFields: cloneStringArray(d.interfaceFields), interfaceFieldTypes: cloneStringArray(d.interfaceFieldTypes), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.StructDecl) { const d = node.data as InterfaceDeclData; const data: NodeData = { interfaceName: d.interfaceName, interfaceFields: cloneStringArray(d.interfaceFields), interfaceFieldTypes: cloneStringArray(d.interfaceFieldTypes), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ClassDecl) { const d = node.data as ClassDeclData; const data: NodeData = { className: d.className, classExtends: d.classExtends, classBody: cloneNodeArray(d.classBody), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.PropertyDecl) { const d = node.data as PropertyDeclData; const data: NodeData = { propName: d.propName, propType: d.propType, propIsStatic: d.propIsStatic, propInitializer: d.propInitializer }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MethodDecl) { const d = node.data as MethodDeclData; const data: NodeData = { methodName: d.methodName, methodParams: cloneStringArray(d.methodParams), methodParamTypes: cloneStringArray(d.methodParamTypes), methodBody: monoCloneNode(d.methodBody), methodIsStatic: d.methodIsStatic, methodFlags: d.methodFlags, methodReturnType: d.methodReturnType, nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ConstructorDecl) { const d = node.data as ConstructorDeclData; const data: NodeData = { ctorParams: cloneStringArray(d.ctorParams), ctorParamTypes: cloneStringArray(d.ctorParamTypes), ctorBody: monoCloneNode(d.ctorBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ThrowStmt) { const d = node.data as ThrowStmtData; const data: NodeData = { throwArg: monoCloneNode(d.throwArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TryCatchStmt) { const d = node.data as TryCatchStmtData; const data: NodeData = { tryBody: monoCloneNode(d.tryBody), catchName: d.catchName, catchBody: monoCloneNode(d.catchBody), finallyBody: monoCloneNode(d.finallyBody), catchBindingLocation: d.catchBindingLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MacroInvocation) { const d = node.data as MacroInvocationData; const data: NodeData = { macroName: d.macroName, macroArgs: cloneNodeArray(d.macroArgs) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.DecoratedDecl) { const d = node.data as DecoratedDeclData; const data: NodeData = { decorators: cloneNodeArray(d.decorators), decoratedNode: monoCloneNode(d.decoratedNode) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.DeferStmt) { const d = node.data as DeferStmtData; const data: NodeData = { deferExpr: monoCloneNode(d.deferExpr) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ExternDecl) { const d = node.data as ExternDeclData; const data: NodeData = { externKind: d.externKind, externName: d.externName, nativeName: d.nativeName, externType: d.externType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MacroDecl) { const d = node.data as MacroDeclData; const data: NodeData = { macroDeclName: d.macroDeclName, macroDeclParams: cloneStringArray(d.macroDeclParams), macroDeclBody: monoCloneNode(d.macroDeclBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.QuoteExpr) { const d = node.data as QuoteExprData; const data: NodeData = { quoteBody: monoCloneNode(d.quoteBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.Program) { const d = node.data as ProgramData; const data: NodeData = { programStmts: cloneNodeArray(d.programStmts) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	return copyNodeMeta(node, createNodeAt(kind, node.data, loc));
}

// ===== Instantiate — clone + substitute types + rename =====

function monoIsAlphaNumOrUnderscore(ch: string): boolean {
	if (ch === "_") return true;
	if (ch === "a" || ch === "b" || ch === "c" || ch === "d" || ch === "e" || ch === "f" || ch === "g" || ch === "h" || ch === "i" || ch === "j" || ch === "k" || ch === "l" || ch === "m" || ch === "n" || ch === "o" || ch === "p" || ch === "q" || ch === "r" || ch === "s" || ch === "t" || ch === "u" || ch === "v" || ch === "w" || ch === "x" || ch === "y" || ch === "z") return true;
	if (ch === "A" || ch === "B" || ch === "C" || ch === "D" || ch === "E" || ch === "F" || ch === "G" || ch === "H" || ch === "I" || ch === "J" || ch === "K" || ch === "L" || ch === "M" || ch === "N" || ch === "O" || ch === "P" || ch === "Q" || ch === "R" || ch === "S" || ch === "T" || ch === "U" || ch === "V" || ch === "W" || ch === "X" || ch === "Y" || ch === "Z") return true;
	if (ch === "0" || ch === "1" || ch === "2" || ch === "3" || ch === "4" || ch === "5" || ch === "6" || ch === "7" || ch === "8" || ch === "9") return true;
	return false;
}

export function monoSubstAnnotation(annotation: string, paramName: string, concreteTypeName: string): string {
	if (annotation === "") return "";
	if (annotation === paramName) return concreteTypeName;
	let result = "";
	let i = 0;
	while (i < annotation.byteLength) {
		let isMatch = true;
		if (i + paramName.byteLength > annotation.byteLength) { isMatch = false; } else {
			for (let pi = 0; pi < paramName.byteLength; pi += 1) { if (annotation.charAt(i + pi) !== paramName.charAt(pi)) { isMatch = false; } }
		}
		if (isMatch) {
			let prevOk = true;
			let nextOk = true;
			if (i > 0) { prevOk = !monoIsAlphaNumOrUnderscore(annotation.charAt(i - 1)); }
			const nextPos = i + paramName.byteLength;
			if (nextPos < annotation.byteLength) { nextOk = !monoIsAlphaNumOrUnderscore(annotation.charAt(nextPos)); }
			if (prevOk && nextOk) { result = result + concreteTypeName; i = i + paramName.byteLength; } else { result = result + annotation.charAt(i); i += 1; }
		} else { result = result + annotation.charAt(i); i += 1; }
	}
	return result;
}

export function monoConcreteTypeName(t: Type): string {
	if (t === null) return "unknown";
	if (t.kind === TypeKind.Number) return "number";
	if (t.kind === TypeKind.String) return "string";
	if (t.kind === TypeKind.Boolean) return "boolean";
	if (t.kind === TypeKind.Void) return "void";
	if (t.kind === TypeKind.Null) return "null";
	if (t.kind === TypeKind.Array) return `Array<${monoConcreteTypeName(t.typeReturn)}>`;
	if (isResult(t)) return `Result<${monoConcreteTypeName(getResultOkType(t))}, ${monoConcreteTypeName(getResultErrType(t))}>`;
	if (t.kind === TypeKind.Struct) return t.typeName;
	if (t.kind === TypeKind.Enum) return t.typeName;
	return "unknown";
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
