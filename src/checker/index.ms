// Checker Hub Module - Re-exports + integration tests

import { test, check, testGroup } from "std/testing";

// Re-exports: types.ms
export { TypeKind, Type } from "./types";
export {
	numberType, stringType, booleanType, voidType,
	nullType, unknownType, neverType, errorType,
} from "./types";
export {
	createPrimitive, createObject, createArray, createFunction,
	createEnum, createResult, createTypeRef,
} from "./types";
export {
	isNumeric, isStringType, isBoolType, isCallable,
	getReturnType, getElementType, getProperty,
	substituteType, instantiateGeneric, createGenericParam,
	isPrimitiveKind, typeNameOf,
} from "./types";

// Re-exports: symbol.ms
export { SymbolKind, ScopeKind, Symbol, Scope, SymbolTable } from "./symbol";
export { createSymbolTable, openScope, closeScope, defineSymbol, lookupSymbol, lookupLocal, lookupExport, makeSymbol, hasOverloads, isPointerType } from "./symbol";

// Re-exports: context.ms
export {
	CheckerContext, createContext, createModuleContext, addError, hasErrors, errorCount,
	ExportedSymInfo, ModuleExports, ExportRegistry,
	createExportRegistry, findModuleExports, findExportedSymbol, registerModuleExports,
	ExtensionMethod, ExtensionRegistry, createExtensionRegistry, registerExtension, findExtension, hasExtensionByName,
	AttachedOps, findAttachedOps, hasAttachedOps,
	isExtensionFlag, getExtReceiverName, getExtReceiverType,
} from "./context";

// Re-exports: collectPass.ms (Pass 1)
export { collectTopLevel, getDeclName } from "./collectPass";

// Re-exports: resolvePass.ms (Pass 2)
export { resolveAnnotation, resolveDeclarations } from "./resolvePass";

// Re-exports: compat.ms
export { isAssignable, TypeRelation, typeRelation, scoreCandidate } from "./compat";

// Re-exports: checkPass.ms (Pass 3 — statements)
export { checkStmt, checkProgramBody, checkProgram, checkSource, runThreePasses } from "./checkPass";

// Re-exports: checkExprPass.ms (Pass 3 — expressions)
export { checkExpr } from "./checkExprPass";

// Re-exports: orchestrator.ms (multi-module orchestration)
export { checkModuleGraph } from "./orchestrator";

// ===== Integration Tests =====

import { TypeKind } from "./types";
import { hasErrors, errorCount } from "./context";
import { checkSource } from "./checkPass";
import { lookupSymbol } from "./symbol";

testGroup("Checker Integration", () => {
	test("full program", () => {
		const ctx = checkSource("const x = 1; function foo(a) { return a; } const y = foo;");
		check(!hasErrors(ctx));
		check(lookupSymbol(ctx.table, "x") !== null);
		check(lookupSymbol(ctx.table, "foo") !== null);
		check(lookupSymbol(ctx.table, "y") !== null);
	});
	test("class + method + variable", () => {
		const ctx = checkSource("class Point { getX() { return 1; } } const p = 1;");
		check(!hasErrors(ctx));
		check(lookupSymbol(ctx.table, "Point") !== null);
		check(lookupSymbol(ctx.table, "p") !== null);
	});
	test("enum + usage", () => {
		const ctx = checkSource("enum Color { Red, Green } const c = Color;");
		check(!hasErrors(ctx));
		check(lookupSymbol(ctx.table, "Color") !== null);
		check(lookupSymbol(ctx.table, "c") !== null);
	});
	test("error count", () => {
		const ctx = checkSource("const x = y; const z = w;");
		check(errorCount(ctx) === 2);
	});
	test("complex program", () => {
		const src = "import { Token } from \"lexer\"; function parse(tokens) { for (const t of tokens) { if (true) { const x = t; } } return 1; }";
		const ctx = checkSource(src);
		check(!hasErrors(ctx));
	});
});

testGroup("3-Pass Integration", () => {
	test("function resolved as callable", () => {
		const ctx = checkSource("function add(a, b) { return 1; }");
		const sym = lookupSymbol(ctx.table, "add");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
		check(sym.symbolType.typeNames.length === 2);
	});
	test("class resolved with members", () => {
		const ctx = checkSource("class Vec { getX() { return 1; } }");
		const sym = lookupSymbol(ctx.table, "Vec");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Object);
	});
	test("arithmetic inference", () => {
		const ctx = checkSource("const x = 2 * 3;");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
	test("comparison inference", () => {
		const ctx = checkSource("const x = 1 >= 2;");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Boolean);
	});
	test("string concat inference", () => {
		const ctx = checkSource("const x = \"hello\" + \" world\";");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.String);
	});
	test("export function resolved", () => {
		const ctx = checkSource("export function greet(name) { return 1; }");
		const sym = lookupSymbol(ctx.table, "greet");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
	});
});
