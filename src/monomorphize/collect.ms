// Monomorphization Collect Pass — find generic definitions + call sites
//
// Reference implementation equivalent: overload resolution triggering instance generation.
// Our approach: eager two-step scan (definitions, then call sites).

import {
	Node, NodeKind, NodeData, DeclKind, SourceLocation,
	ProgramData, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData,
	ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	ClassDeclData, MethodDeclData, ConstructorDeclData,
	ExportDeclData, DecoratedDeclData, MacroDeclData,
	VariableDeclData, ReturnStmtData, ThrowStmtData, ExprStmtData,
	TryCatchStmtData, DeferStmtData,
	BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	SpreadExprData, NewExprData, TryExprData,
	MatchExprData, MatchStmtData, MatchCaseData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData,
	TypeAssertionData, DestructuringDeclData, QuoteExprData,
	MacroInvocationData,
	IdentifierData, NumberLiteralData, StringLiteralData, BooleanLiteralData,
	ImportDeclData, TypeAliasDeclData, EnumDeclData, InterfaceDeclData,
	PropertyDeclData, ExternDeclData, TypeAnnotationData,
	BreakStmtData, ContinueStmtData, UnreachableStmtData,
	BigIntLiteralData, RegexLiteralData,
	HiddenStdConvData,
	createNodeAt,
} from "../ast/node";
import { Type, TypeKind, unknownType, numberType, stringType, booleanType, nullType, createFunction, createArray, unifyType, createUnifyBindings } from "../checker/types";
import { CheckerContext, extractGenericNames, stripGenFlag } from "../checker/context";
import { SymbolTable, Symbol, SymbolKind, ScopeKind, lookupSymbol, defineSymbol, makeSymbol, openScope, closeScope } from "../checker/symbol";
import { MonoRegistry, MonoEntry, monoRegister, monoFindEntry, buildTypeArgKeys, monoTypeKey, createMonoRegistry } from "./registry";
import { sliceStr, trimStr, splitTopLevel, findChar, charAt } from "../utils/string";
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
	for (let i = 0; i < parts.length; i += 1) {
		const name = trimStr(parts[i]);
		const resolved = monoResolveTypeName(name);
		if (resolved !== null) result.push(resolved);
	}
	return result;
}

function monoResolveTypeName(name: string): Type {
	if (name === "number") return { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	if (name === "string") return { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	if (name === "boolean") return { kind: TypeKind.Boolean, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	if (name === "void") return { kind: TypeKind.Void, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	// Named types (interfaces, classes, enums)
	return { kind: TypeKind.Object, typeName: name, typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
}

// ===== Resolve Annotation String → Type =====
// Local resolver for monomorphized type annotations. Avoids importing resolvePass
// (DRC safety). Handles primitives, arrays, and named types.

function monoResolveAnnotation(annotation: string): Type {
	const trimmed = trimStr(annotation);
	if (trimmed === "") return unknownType();
	// Array suffix: number[]
	if (trimmed.length > 2) {
		const suffix = sliceStr(trimmed, trimmed.length - 2, trimmed.length);
		if (suffix === "[]") {
			const inner = sliceStr(trimmed, 0, trimmed.length - 2);
			return createArray(monoResolveAnnotation(inner));
		}
	}
	// Token-joined form: number [ ]
	if (trimmed.length > 4) {
		const suffix3 = sliceStr(trimmed, trimmed.length - 3, trimmed.length);
		if (suffix3 === "[ ]") {
			const inner = trimStr(sliceStr(trimmed, 0, trimmed.length - 3));
			return createArray(monoResolveAnnotation(inner));
		}
	}
	// Generic types: Array<X>
	const angleBracket = findChar(trimmed, "<");
	if (angleBracket > 0) {
		const lastChar = charAt(trimmed, trimmed.length - 1);
		if (lastChar === ">") {
			const baseName = trimStr(sliceStr(trimmed, 0, angleBracket));
			const argsText = trimStr(sliceStr(trimmed, angleBracket + 1, trimmed.length - 1));
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
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		monoCollectDefStmt(pd.programStmts[i], declMap);
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
	monoWalkForCalls(program, declMap, registry, checkerCtx);
}

// Recursive AST walk using if-else (not match — DRC workaround #24)
function monoWalkForCalls(
	node: Node,
	declMap: MonoGenericDeclMap,
	registry: MonoRegistry,
	ctx: CheckerContext
): void {
	if (node === null) return;
	const kind = node.kind;

	// Check CallExpr first
	if (kind === NodeKind.CallExpr) {
		monoProcessCallExpr(node, declMap, registry, ctx);
		// Also walk children of the call (callee and args may contain more calls)
		const d = node.data as CallExprData;
		monoWalkForCalls(d.callee, declMap, registry, ctx);
		for (const arg of d.arguments) {
			monoWalkForCalls(arg, declMap, registry, ctx);
		}
		return;
	}

	// Recurse into all children (if-else chain for DRC safety)
	if (kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		for (const s of d.programStmts) { monoWalkForCalls(s, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const s of d.statements) { monoWalkForCalls(s, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		monoWalkForCalls(d.fnBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		monoWalkForCalls(d.arrowBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		monoWalkForCalls(d.funcExprBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		monoWalkForCalls(d.condition, declMap, registry, ctx);
		monoWalkForCalls(d.consequent, declMap, registry, ctx);
		monoWalkForCalls(d.alternate, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		monoWalkForCalls(d.whileCondition, declMap, registry, ctx);
		monoWalkForCalls(d.whileBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		monoWalkForCalls(d.forInit, declMap, registry, ctx);
		monoWalkForCalls(d.forCondition, declMap, registry, ctx);
		monoWalkForCalls(d.forUpdate, declMap, registry, ctx);
		monoWalkForCalls(d.forBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		monoWalkForCalls(d.forOfIterable, declMap, registry, ctx);
		monoWalkForCalls(d.forOfBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		monoWalkForCalls(d.forInObject, declMap, registry, ctx);
		monoWalkForCalls(d.forInBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		monoWalkForCalls(d.doBody, declMap, registry, ctx);
		monoWalkForCalls(d.doCondition, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		monoWalkForCalls(d.argument, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		monoWalkForCalls(d.expr, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		monoWalkForCalls(d.initializer, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		monoWalkForCalls(d.left, declMap, registry, ctx);
		monoWalkForCalls(d.right, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		monoWalkForCalls(d.operand, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		monoWalkForCalls(d.ternaryCondition, declMap, registry, ctx);
		monoWalkForCalls(d.ternaryConsequent, declMap, registry, ctx);
		monoWalkForCalls(d.ternaryAlternate, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		monoWalkForCalls(d.object, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		monoWalkForCalls(d.array, declMap, registry, ctx);
		monoWalkForCalls(d.index, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		for (const p of d.properties) { monoWalkForCalls(p, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		for (const e of d.elements) { monoWalkForCalls(e, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		monoWalkForCalls(d.tryBody, declMap, registry, ctx);
		monoWalkForCalls(d.catchBody, declMap, registry, ctx);
		monoWalkForCalls(d.finallyBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ThrowStmt) {
		const d = node.data as ThrowStmtData;
		monoWalkForCalls(d.throwArg, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		monoWalkForCalls(d.exportedDecl, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		monoWalkForCalls(d.decoratedNode, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		monoWalkForCalls(d.switchDisc, declMap, registry, ctx);
		for (const c of d.switchCases) { monoWalkForCalls(c, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		for (const s of d.caseStmts) { monoWalkForCalls(s, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		monoWalkForCalls(d.matchStmtDisc, declMap, registry, ctx);
		for (const c of d.matchStmtCases) { monoWalkForCalls(c, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		monoWalkForCalls(d.matchDisc, declMap, registry, ctx);
		for (const c of d.matchCases) { monoWalkForCalls(c, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.MatchCase) {
		const d = node.data as MatchCaseData;
		monoWalkForCalls(d.caseBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.SpreadExpr) {
		const d = node.data as SpreadExprData;
		monoWalkForCalls(d.spreadArg, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		monoWalkForCalls(d.newCallee, declMap, registry, ctx);
		for (const a of d.newArguments) { monoWalkForCalls(a, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.TryExpr) {
		const d = node.data as TryExprData;
		monoWalkForCalls(d.tryArg, declMap, registry, ctx);
		if (d.hasCatch) { monoWalkForCalls(d.catchVal, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		for (const m of d.classBody) { monoWalkForCalls(m, declMap, registry, ctx); }
		return;
	}
	if (kind === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		monoWalkForCalls(d.methodBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		monoWalkForCalls(d.ctorBody, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		monoWalkForCalls(d.asExpr, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		monoWalkForCalls(d.updateArg, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.DestructuringDecl) {
		const d = node.data as DestructuringDeclData;
		monoWalkForCalls(d.destrPattern, declMap, registry, ctx);
		monoWalkForCalls(d.destrInit, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.DeferStmt) {
		const d = node.data as DeferStmtData;
		monoWalkForCalls(d.deferExpr, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		monoWalkForCalls(d.awaitArg, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.YieldExpr) {
		const d = node.data as YieldExprData;
		monoWalkForCalls(d.yieldArg, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) {
		const d = node.data as ExprStmtData;
		monoWalkForCalls(d.expr, declMap, registry, ctx);
		return;
	}
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) {
		const d = node.data as HiddenStdConvData;
		monoWalkForCalls(d.convExpr, declMap, registry, ctx);
		return;
	}
	// Leaf nodes (Identifier, literals, break, continue, etc.): no children to walk
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
	if (node === null) return null as unknown as Type;

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

	return null as unknown as Type;
}

// ===== Pass 3: Rewrite Walk =====
// Recursive walk using if-else (DRC workaround #24).
// Merged here to avoid separate rewrite.ms import (DRC workaround #27).

export function monoRewriteNode(
	node: Node,
	registry: MonoRegistry,
	declMap: MonoGenericDeclMap,
	ctx: CheckerContext
): void {
	if (node === null) return;
	const kind = node.kind;

	if (kind === NodeKind.CallExpr) {
		monoRewriteCallExpr(node, registry, declMap, ctx);
		const d = node.data as CallExprData;
		monoRewriteNode(d.callee, registry, declMap, ctx);
		for (const arg of d.arguments) {
			monoRewriteNode(arg, registry, declMap, ctx);
		}
		return;
	}
	if (kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		for (const s of d.programStmts) { monoRewriteNode(s, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const s of d.statements) { monoRewriteNode(s, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		monoRewriteNode(d.fnBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		monoRewriteNode(d.arrowBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		monoRewriteNode(d.funcExprBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		monoRewriteNode(d.condition, registry, declMap, ctx);
		monoRewriteNode(d.consequent, registry, declMap, ctx);
		monoRewriteNode(d.alternate, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		monoRewriteNode(d.whileCondition, registry, declMap, ctx);
		monoRewriteNode(d.whileBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		monoRewriteNode(d.forInit, registry, declMap, ctx);
		monoRewriteNode(d.forCondition, registry, declMap, ctx);
		monoRewriteNode(d.forUpdate, registry, declMap, ctx);
		monoRewriteNode(d.forBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		monoRewriteNode(d.forOfIterable, registry, declMap, ctx);
		monoRewriteNode(d.forOfBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		monoRewriteNode(d.forInObject, registry, declMap, ctx);
		monoRewriteNode(d.forInBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		monoRewriteNode(d.doBody, registry, declMap, ctx);
		monoRewriteNode(d.doCondition, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		monoRewriteNode(d.argument, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		monoRewriteNode(d.expr, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		monoRewriteNode(d.initializer, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		monoRewriteNode(d.left, registry, declMap, ctx);
		monoRewriteNode(d.right, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		monoRewriteNode(d.operand, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		monoRewriteNode(d.ternaryCondition, registry, declMap, ctx);
		monoRewriteNode(d.ternaryConsequent, registry, declMap, ctx);
		monoRewriteNode(d.ternaryAlternate, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		monoRewriteNode(d.object, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		monoRewriteNode(d.array, registry, declMap, ctx);
		monoRewriteNode(d.index, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		for (const p of d.properties) { monoRewriteNode(p, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		for (const e of d.elements) { monoRewriteNode(e, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		monoRewriteNode(d.tryBody, registry, declMap, ctx);
		monoRewriteNode(d.catchBody, registry, declMap, ctx);
		monoRewriteNode(d.finallyBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ThrowStmt) {
		const d = node.data as ThrowStmtData;
		monoRewriteNode(d.throwArg, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		monoRewriteNode(d.exportedDecl, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		monoRewriteNode(d.decoratedNode, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		monoRewriteNode(d.switchDisc, registry, declMap, ctx);
		for (const c of d.switchCases) { monoRewriteNode(c, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		for (const s of d.caseStmts) { monoRewriteNode(s, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		monoRewriteNode(d.matchStmtDisc, registry, declMap, ctx);
		for (const c of d.matchStmtCases) { monoRewriteNode(c, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		monoRewriteNode(d.matchDisc, registry, declMap, ctx);
		for (const c of d.matchCases) { monoRewriteNode(c, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.MatchCase) {
		const d = node.data as MatchCaseData;
		monoRewriteNode(d.caseBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.SpreadExpr) {
		const d = node.data as SpreadExprData;
		monoRewriteNode(d.spreadArg, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		monoRewriteNode(d.newCallee, registry, declMap, ctx);
		for (const a of d.newArguments) { monoRewriteNode(a, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.TryExpr) {
		const d = node.data as TryExprData;
		monoRewriteNode(d.tryArg, registry, declMap, ctx);
		if (d.hasCatch) { monoRewriteNode(d.catchVal, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		for (const m of d.classBody) { monoRewriteNode(m, registry, declMap, ctx); }
		return;
	}
	if (kind === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		monoRewriteNode(d.methodBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		monoRewriteNode(d.ctorBody, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		monoRewriteNode(d.asExpr, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		monoRewriteNode(d.updateArg, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.DestructuringDecl) {
		const d = node.data as DestructuringDeclData;
		monoRewriteNode(d.destrPattern, registry, declMap, ctx);
		monoRewriteNode(d.destrInit, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.DeferStmt) {
		const d = node.data as DeferStmtData;
		monoRewriteNode(d.deferExpr, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		monoRewriteNode(d.awaitArg, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.YieldExpr) {
		const d = node.data as YieldExprData;
		monoRewriteNode(d.yieldArg, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) {
		const d = node.data as ExprStmtData;
		monoRewriteNode(d.expr, registry, declMap, ctx);
		return;
	}
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) {
		const d = node.data as HiddenStdConvData;
		monoRewriteNode(d.convExpr, registry, declMap, ctx);
		return;
	}
}

// Rewrite a single CallExpr — replace callee with monomorphized name
function monoRewriteCallExpr(
	node: Node,
	registry: MonoRegistry,
	declMap: MonoGenericDeclMap,
	ctx: CheckerContext
): void {
	const d = node.data as CallExprData;
	if (d.callee === null) return;
	if (d.callee.kind !== NodeKind.Identifier) return;

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

	// Rewrite callee name in-place
	const calleeId = d.callee.data as IdentifierData;
	calleeId.name = entry.mangledName;
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

function monoCloneNode(node: Node): Node {
	if (node === null) return null as unknown as Node;
	const loc: SourceLocation = { line: node.location.line, column: node.location.column };
	const kind = node.kind;

	if (kind === NodeKind.NumberLiteral) { const d = node.data as NumberLiteralData; const data: NodeData = { value: d.value }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.StringLiteral) { const d = node.data as StringLiteralData; const data: NodeData = { value: d.value }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.BooleanLiteral) { const d = node.data as BooleanLiteralData; const data: NodeData = { boolValue: d.boolValue }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.NullLiteral) { const data: NodeData = { nullPlaceholder: true }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.BigIntLiteral) { const d = node.data as BigIntLiteralData; const data: NodeData = { bigintValue: d.bigintValue }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.RegexLiteral) { const d = node.data as RegexLiteralData; const data: NodeData = { regexPattern: d.regexPattern }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.Identifier) { const d = node.data as IdentifierData; const data: NodeData = { name: d.name }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.BinaryExpr) { const d = node.data as BinaryExprData; const data: NodeData = { operator: d.operator, left: monoCloneNode(d.left), right: monoCloneNode(d.right) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.UnaryExpr) { const d = node.data as UnaryExprData; const data: NodeData = { unaryOp: d.unaryOp, operand: monoCloneNode(d.operand) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.UpdateExpr) { const d = node.data as UpdateExprData; const data: NodeData = { updateOp: d.updateOp, updateArg: monoCloneNode(d.updateArg), isPrefix: d.isPrefix }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.CallExpr) { const d = node.data as CallExprData; const data: NodeData = { callee: monoCloneNode(d.callee), arguments: cloneNodeArray(d.arguments), isDirectCall: d.isDirectCall, resolvedOverloadIdx: d.resolvedOverloadIdx }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.MemberExpr) { const d = node.data as MemberExprData; const data: NodeData = { object: monoCloneNode(d.object), property: d.property, isOptional: d.isOptional }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ArrayAccess) { const d = node.data as ArrayAccessData; const data: NodeData = { array: monoCloneNode(d.array), index: monoCloneNode(d.index) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ObjectLiteral) { const d = node.data as ObjectLiteralData; const data: NodeData = { properties: cloneNodeArray(d.properties), keys: cloneStringArray(d.keys) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ArrayLiteral) { const d = node.data as ArrayLiteralData; const data: NodeData = { elements: cloneNodeArray(d.elements) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ArrowFunction) { const d = node.data as ArrowFunctionData; const data: NodeData = { arrowParams: cloneStringArray(d.arrowParams), arrowParamTypes: cloneStringArray(d.arrowParamTypes), arrowBody: monoCloneNode(d.arrowBody), arrowFlags: d.arrowFlags, arrowReturnType: d.arrowReturnType }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.FunctionExpr) { const d = node.data as FunctionExprData; const data: NodeData = { funcExprParams: cloneStringArray(d.funcExprParams), funcExprParamTypes: cloneStringArray(d.funcExprParamTypes), funcExprBody: monoCloneNode(d.funcExprBody), funcExprFlags: d.funcExprFlags, funcExprReturnType: d.funcExprReturnType }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.TypeAssertion) { const d = node.data as TypeAssertionData; const data: NodeData = { asExpr: monoCloneNode(d.asExpr), asType: d.asType }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ConditionalExpr) { const d = node.data as ConditionalExprData; const data: NodeData = { ternaryCondition: monoCloneNode(d.ternaryCondition), ternaryConsequent: monoCloneNode(d.ternaryConsequent), ternaryAlternate: monoCloneNode(d.ternaryAlternate) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.SpreadExpr) { const d = node.data as SpreadExprData; const data: NodeData = { spreadArg: monoCloneNode(d.spreadArg) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.NewExpr) { const d = node.data as NewExprData; const data: NodeData = { newCallee: monoCloneNode(d.newCallee), newArguments: cloneNodeArray(d.newArguments) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.TryExpr) { const d = node.data as TryExprData; const data: NodeData = { tryArg: monoCloneNode(d.tryArg), hasCatch: d.hasCatch, catchVal: d.hasCatch ? monoCloneNode(d.catchVal) : null as unknown as Node }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.MatchExpr) { const d = node.data as MatchExprData; const data: NodeData = { matchDisc: monoCloneNode(d.matchDisc), matchCases: cloneNodeArray(d.matchCases) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.MatchCase) { const d = node.data as MatchCaseData; const data: NodeData = { casePatterns: cloneNodeArray(d.casePatterns), caseBody: monoCloneNode(d.caseBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.AwaitExpr) { const d = node.data as AwaitExprData; const data: NodeData = { awaitArg: monoCloneNode(d.awaitArg) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.YieldExpr) { const d = node.data as YieldExprData; const data: NodeData = { yieldArg: monoCloneNode(d.yieldArg), isDelegate: d.isDelegate }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.MoveExpr) { const d = node.data as MoveExprData; const data: NodeData = { moveArg: monoCloneNode(d.moveArg) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.OutExpr) { const d = node.data as OutExprData; const data: NodeData = { outArg: monoCloneNode(d.outArg) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.SizeofExpr) { const d = node.data as SizeofExprData; const data: NodeData = { sizeofType: d.sizeofType }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) { const d = node.data as ExprStmtData; const data: NodeData = { expr: monoCloneNode(d.expr) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) { const d = node.data as HiddenStdConvData; const data: NodeData = { convExpr: monoCloneNode(d.convExpr), convType: d.convType }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.TypeAnnotation) { const d = node.data as TypeAnnotationData; const data: NodeData = { annotationType: d.annotationType }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.DestructuringDecl) { const d = node.data as DestructuringDeclData; const data: NodeData = { destrPattern: monoCloneNode(d.destrPattern), destrInit: monoCloneNode(d.destrInit), destrIsConst: d.destrIsConst }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.VariableDecl) { const d = node.data as VariableDeclData; const data: NodeData = { declName: d.declName, declType: d.declType, initializer: monoCloneNode(d.initializer), declKind: d.declKind }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.IfStmt) { const d = node.data as IfStmtData; const data: NodeData = { condition: monoCloneNode(d.condition), consequent: monoCloneNode(d.consequent), alternate: monoCloneNode(d.alternate) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.WhileStmt) { const d = node.data as WhileStmtData; const data: NodeData = { whileCondition: monoCloneNode(d.whileCondition), whileBody: monoCloneNode(d.whileBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ForStmt) { const d = node.data as ForStmtData; const data: NodeData = { forInit: monoCloneNode(d.forInit), forCondition: monoCloneNode(d.forCondition), forUpdate: monoCloneNode(d.forUpdate), forBody: monoCloneNode(d.forBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ForOfStmt) { const d = node.data as ForOfStmtData; const data: NodeData = { forOfBinding: d.forOfBinding, forOfIsConst: d.forOfIsConst, forOfIterable: monoCloneNode(d.forOfIterable), forOfBody: monoCloneNode(d.forOfBody), forOfPattern: d.forOfPattern !== null ? monoCloneNode(d.forOfPattern) : null as unknown as Node }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ForInStmt) { const d = node.data as ForInStmtData; const data: NodeData = { forInBinding: d.forInBinding, forInIsConst: d.forInIsConst, forInObject: monoCloneNode(d.forInObject), forInBody: monoCloneNode(d.forInBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.DoWhileStmt) { const d = node.data as DoWhileStmtData; const data: NodeData = { doBody: monoCloneNode(d.doBody), doCondition: monoCloneNode(d.doCondition) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.BlockStmt) { const d = node.data as BlockStmtData; const data: NodeData = { statements: cloneNodeArray(d.statements) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ExprStmt) { const d = node.data as ExprStmtData; const data: NodeData = { expr: monoCloneNode(d.expr) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ReturnStmt) { const d = node.data as ReturnStmtData; const data: NodeData = { argument: monoCloneNode(d.argument) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.BreakStmt) { const d = node.data as BreakStmtData; const data: NodeData = { breakLabel: d.breakLabel }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ContinueStmt) { const d = node.data as ContinueStmtData; const data: NodeData = { continueLabel: d.continueLabel }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.UnreachableStmt) { const d = node.data as UnreachableStmtData; const data: NodeData = { unreachableMsg: d.unreachableMsg }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.FunctionDecl) { const d = node.data as FunctionDeclData; const data: NodeData = { fnName: d.fnName, params: cloneStringArray(d.params), fnParamTypes: cloneStringArray(d.fnParamTypes), fnBody: monoCloneNode(d.fnBody), fnFlags: d.fnFlags, fnReturnType: d.fnReturnType, fnDefaults: cloneStringArray(d.fnDefaults) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.SwitchStmt) { const d = node.data as SwitchStmtData; const data: NodeData = { switchDisc: monoCloneNode(d.switchDisc), switchCases: cloneNodeArray(d.switchCases) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.SwitchCase) { const d = node.data as SwitchCaseData; const data: NodeData = { caseTests: cloneNodeArray(d.caseTests), caseStmts: cloneNodeArray(d.caseStmts), isDefault: d.isDefault }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.MatchStmt) { const d = node.data as MatchStmtData; const data: NodeData = { matchStmtDisc: monoCloneNode(d.matchStmtDisc), matchStmtCases: cloneNodeArray(d.matchStmtCases) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ImportDecl) { const d = node.data as ImportDeclData; const data: NodeData = { importNames: cloneStringArray(d.importNames), importAliases: cloneStringArray(d.importAliases), importSource: d.importSource }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ExportDecl) { const d = node.data as ExportDeclData; const data: NodeData = { exportedDecl: monoCloneNode(d.exportedDecl) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.TypeAliasDecl) { const d = node.data as TypeAliasDeclData; const data: NodeData = { aliasName: d.aliasName, aliasType: d.aliasType, aliasIsDistinct: d.aliasIsDistinct }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.EnumDecl) { const d = node.data as EnumDeclData; const data: NodeData = { enumName: d.enumName, enumMembers: cloneStringArray(d.enumMembers) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.InterfaceDecl) { const d = node.data as InterfaceDeclData; const data: NodeData = { interfaceName: d.interfaceName, interfaceFields: cloneStringArray(d.interfaceFields), interfaceFieldTypes: cloneStringArray(d.interfaceFieldTypes) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ClassDecl) { const d = node.data as ClassDeclData; const data: NodeData = { className: d.className, classExtends: d.classExtends, classBody: cloneNodeArray(d.classBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.PropertyDecl) { const d = node.data as PropertyDeclData; const data: NodeData = { propName: d.propName, propType: d.propType, propIsStatic: d.propIsStatic }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.MethodDecl) { const d = node.data as MethodDeclData; const data: NodeData = { methodName: d.methodName, methodParams: cloneStringArray(d.methodParams), methodParamTypes: cloneStringArray(d.methodParamTypes), methodBody: monoCloneNode(d.methodBody), methodIsStatic: d.methodIsStatic, methodFlags: d.methodFlags, methodReturnType: d.methodReturnType }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ConstructorDecl) { const d = node.data as ConstructorDeclData; const data: NodeData = { ctorParams: cloneStringArray(d.ctorParams), ctorParamTypes: cloneStringArray(d.ctorParamTypes), ctorBody: monoCloneNode(d.ctorBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ThrowStmt) { const d = node.data as ThrowStmtData; const data: NodeData = { throwArg: monoCloneNode(d.throwArg) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.TryCatchStmt) { const d = node.data as TryCatchStmtData; const data: NodeData = { tryBody: monoCloneNode(d.tryBody), catchName: d.catchName, catchBody: monoCloneNode(d.catchBody), finallyBody: monoCloneNode(d.finallyBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.MacroInvocation) { const d = node.data as MacroInvocationData; const data: NodeData = { macroName: d.macroName, macroArgs: cloneNodeArray(d.macroArgs) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.DecoratedDecl) { const d = node.data as DecoratedDeclData; const data: NodeData = { decorators: cloneNodeArray(d.decorators), decoratedNode: monoCloneNode(d.decoratedNode) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.DeferStmt) { const d = node.data as DeferStmtData; const data: NodeData = { deferExpr: monoCloneNode(d.deferExpr) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.ExternDecl) { const d = node.data as ExternDeclData; const data: NodeData = { externKind: d.externKind, externName: d.externName, nativeName: d.nativeName, externType: d.externType }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.MacroDecl) { const d = node.data as MacroDeclData; const data: NodeData = { macroDeclName: d.macroDeclName, macroDeclParams: cloneStringArray(d.macroDeclParams), macroDeclBody: monoCloneNode(d.macroDeclBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.QuoteExpr) { const d = node.data as QuoteExprData; const data: NodeData = { quoteBody: monoCloneNode(d.quoteBody) }; return createNodeAt(kind, data, loc); }
	if (kind === NodeKind.Program) { const d = node.data as ProgramData; const data: NodeData = { programStmts: cloneNodeArray(d.programStmts) }; return createNodeAt(kind, data, loc); }
	return createNodeAt(kind, node.data, loc);
}

// ===== Instantiate — clone + substitute types + rename =====

function monoIsAlphaNumOrUnderscore(ch: string): boolean {
	if (ch === "_") return true;
	if (ch === "a" || ch === "b" || ch === "c" || ch === "d" || ch === "e" || ch === "f" || ch === "g" || ch === "h" || ch === "i" || ch === "j" || ch === "k" || ch === "l" || ch === "m" || ch === "n" || ch === "o" || ch === "p" || ch === "q" || ch === "r" || ch === "s" || ch === "t" || ch === "u" || ch === "v" || ch === "w" || ch === "x" || ch === "y" || ch === "z") return true;
	if (ch === "A" || ch === "B" || ch === "C" || ch === "D" || ch === "E" || ch === "F" || ch === "G" || ch === "H" || ch === "I" || ch === "J" || ch === "K" || ch === "L" || ch === "M" || ch === "N" || ch === "O" || ch === "P" || ch === "Q" || ch === "R" || ch === "S" || ch === "T" || ch === "U" || ch === "V" || ch === "W" || ch === "X" || ch === "Y" || ch === "Z") return true;
	if (ch === "0" || ch === "1" || ch === "2" || ch === "3" || ch === "4" || ch === "5" || ch === "6" || ch === "7" || ch === "8" || ch === "9") return true;
	return false;
}

function monoSubstAnnotation(annotation: string, paramName: string, concreteTypeName: string): string {
	if (annotation === "") return "";
	if (annotation === paramName) return concreteTypeName;
	let result = "";
	let i = 0;
	while (i < annotation.length) {
		let isMatch = true;
		if (i + paramName.length > annotation.length) { isMatch = false; } else {
			for (let pi = 0; pi < paramName.length; pi += 1) { if (charAt(annotation, i + pi) !== charAt(paramName, pi)) { isMatch = false; } }
		}
		if (isMatch) {
			let prevOk = true;
			let nextOk = true;
			if (i > 0) { prevOk = !monoIsAlphaNumOrUnderscore(charAt(annotation, i - 1)); }
			const nextPos = i + paramName.length;
			if (nextPos < annotation.length) { nextOk = !monoIsAlphaNumOrUnderscore(charAt(annotation, nextPos)); }
			if (prevOk && nextOk) { result = result + concreteTypeName; i = i + paramName.length; } else { result = result + charAt(annotation, i); i += 1; }
		} else { result = result + charAt(annotation, i); i += 1; }
	}
	return result;
}

function monoConcreteTypeName(t: Type): string {
	if (t === null) return "unknown";
	if (t.kind === TypeKind.Number) return "number";
	if (t.kind === TypeKind.String) return "string";
	if (t.kind === TypeKind.Boolean) return "boolean";
	if (t.kind === TypeKind.Void) return "void";
	if (t.kind === TypeKind.Null) return "null";
	if (t.kind === TypeKind.Array) return "Array<" + monoConcreteTypeName(t.typeReturn) + ">";
	if (t.kind === TypeKind.Result) return "Result<" + monoConcreteTypeName(t.typeReturn) + ", " + monoConcreteTypeName(t.typeExtra) + ">";
	if (t.kind === TypeKind.Object) return t.typeName;
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
					monoWalkForCalls(cloned, declMap, registry, ctx);
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
	const loc: SourceLocation = { line: 0, column: 0 };
	const data: NodeData = { interfaceName: mangledName, interfaceFields: fieldNames, interfaceFieldTypes: fieldTypes };
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
	monoEmitTypeInstNodes(program);

	const pd = program.data as ProgramData;

	// Phase 2: Monomorphize generic functions
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
	monoRewriteNode(program, registry, declMap, checkerCtx);
	for (const gn of generatedNodes) {
		monoRewriteNode(gn, registry, declMap, checkerCtx);
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
	assert t.kind === TypeKind.Object;
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
	assert t.kind === TypeKind.Object;
	assert t.typeName === "MyInterface";
}

test "resolveAnnotation empty" { assert monoResolveAnnotation("").kind === TypeKind.Unknown; }
