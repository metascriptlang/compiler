// Checker Hub Module - Re-exports + integration tests



// Re-exports: types.ms
export { TypeKind, Type } from "../ast/node";
export {
	numberType, stringType, booleanType, voidType, charType,
	nullType, unknownType, neverType, errorType,
} from "./types";
export {
	createPrimitive, createStruct, createArray, createSizedArray, createSpan, createFunction,
	createEnum, createResult, createTypeRef, createGenericParam,
} from "./types";
export {
	isNumeric, isStringType, isBoolType, isCallable,
	getReturnType, getElementType, getProperty,
	substituteType, instantiateGeneric,
	isPrimitiveKind, typeNameOf,
	UnifyBindings, createUnifyBindings, unifyType, hasGenericParams,
} from "./types";

// Re-exports: symbol.ms
export { SymbolKind, Symbol } from "../ast/node";
export { ScopeKind, Scope, SymbolTable, SymbolFlag } from "./symbol";
// Explicit exports for helpers to avoid ambiguity
export { createSymbolTable, openScope, closeScope, defineSymbol, lookupSymbol, lookupLocal, lookupExport, makeSymbol, hasOverloads, isPointerType } from "./symbol";

// Re-exports: context.ms
export {
	CancelCtx, isCancelled,
	CheckerContext, createContext, createModuleContext, addError, hasErrors, errorCount,
	ExportedSymInfo, ModuleExports, ExportRegistry,
	createExportRegistry, findModuleExports, findExportedSymbol, registerModuleExports,
	ExtensionMethod, ExtensionRegistry, createExtensionRegistry, registerExtension, findExtension, hasExtensionByName,
	AttachedOps, findAttachedOps, hasAttachedOps,
	isExtensionFlag, isStaticExtensionFlag, getExtReceiverName, getExtReceiverType, getStaticExtTypeName, getExtTypeName,
} from "./context";

// Re-exports: collectPass.ms (Pass 1)
export { collectTopLevel, collectTopLevelLocal, getDeclName } from "./collectPass";

// Re-exports: resolvePass.ms (Pass 2)
export { resolveAnnotation, resolveDeclarations } from "./resolvePass";

// Re-exports: compat.ms
export { isAssignable, TypeRelation, typeRelation, scoreCandidate } from "./compat";

// Re-exports: checkPass.ms (Pass 3 — statements)
export { checkStmt, checkProgramBody, checkProgram, checkProgramWithRegistry, checkProgramWithRegistryCancellable, checkSource, runThreePasses, buildPreludeContext } from "./checkPass";

// Re-exports: checkExprPass.ms (Pass 3 — expressions)
export { checkExpr } from "./checkExprPass";

// Re-exports: initTracker.ms (definite assignment)
export { InitTracker, BreakState, createInitTracker, markInitialized, isInitialized, impliesNotNull } from "./initTracker";

// Re-exports: orchestrator.ms (module graph orchestration)
export { checkModuleGraph, getPreludeContext } from "./orchestrator";

// ===== Integration Tests =====

import { TypeKind } from "../ast/node";
import { hasErrors, errorCount } from "./context";
import { checkSource } from "./checkPass";
import { lookupSymbol } from "./symbol";
test "full program" {
	const ctx = checkSource("const x = 1; function foo(a) { return a; } const y = foo;");
	assert !hasErrors(ctx);
	assert lookupSymbol(ctx.table, "x") !== null;
	assert lookupSymbol(ctx.table, "foo") !== null;
	assert lookupSymbol(ctx.table, "y") !== null;
}

test "class + method + variable" {
	const ctx = checkSource("class Point { getX() { return 1; } } const p = 1;");
	assert !hasErrors(ctx);
	assert lookupSymbol(ctx.table, "Point") !== null;
	assert lookupSymbol(ctx.table, "p") !== null;
}

test "enum + usage" {
	const ctx = checkSource("enum Color { Red, Green } const c = Color;");
	assert !hasErrors(ctx);
	assert lookupSymbol(ctx.table, "Color") !== null;
	assert lookupSymbol(ctx.table, "c") !== null;
}

test "error count" {
	const ctx = checkSource("const x = y; const z = w;");
	assert errorCount(ctx) === 2;
}

test "complex program" {
	const src = "import { Token } from \"lexer\"; function parse(tokens) { for (const t of tokens) { if (true) { const x = t; } } return 1; }";
	const ctx = checkSource(src);
	assert !hasErrors(ctx);
}

test "function resolved as callable" {
	const ctx = checkSource("function add(a, b) { return 1; }");
	const sym = lookupSymbol(ctx.table, "add");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeNames.length === 2;
}

test "class resolved as Ref<Object>" {
	const ctx = checkSource("class Vec { getX() { return 1; } }");
	const sym = lookupSymbol(ctx.table, "Vec");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Ref;
}

test "arithmetic inference" {
	const ctx = checkSource("const x = 2 * 3;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "comparison inference" {
	const ctx = checkSource("const x = 1 >= 2;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "string concat inference" {
	const ctx = checkSource("const x = \"hello\" + \" world\";");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "export function resolved" {
	const ctx = checkSource("export function greet(name) { return 1; }");
	const sym = lookupSymbol(ctx.table, "greet");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
}
