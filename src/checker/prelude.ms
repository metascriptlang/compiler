// Prelude — auto-imported symbols available in every module without explicit import.
// Nim parallel: system.nim  |  Mechanism: inject into Global scope before user code.
//
// User code runs in a child Module scope, so prelude names can be shadowed.
// See docs/LANG-PRELUDE.md for full design.

import { Type, TypeKind, createFunction, numberType, stringType, booleanType, voidType } from "./types";
import { Symbol, SymbolKind, SymbolTable, defineSymbol, makeSymbol, lookupSymbol, openScope, closeScope, ScopeKind, createSymbolTable } from "./symbol";
import { test, check, testGroup } from "std/testing";

// ===== Prelude Symbol Construction =====

function definePreludeFn(table: SymbolTable, name: string, paramNames: string[],
                          paramTypes: Type[], retType: Type, rtName: string, btKind: string): void {
	const fnType = createFunction(paramTypes, paramNames, retType);
	const sym = makeSymbol(name, SymbolKind.Function, fnType, false);
	sym.runtimeName = rtName;
	sym.builtinKind = btKind;
	defineSymbol(table, sym);
}

export function injectPrelude(table: SymbolTable): void {
	// I/O
	definePreludeFn(table, "print",   ["value"], [stringType()],  voidType(),   "ms_print", "");
	definePreludeFn(table, "println", ["value"], [stringType()],  voidType(),   "ms_println", "");

	// Math
	definePreludeFn(table, "floor", ["x"], [numberType()], numberType(), "ms_floor", "");
	definePreludeFn(table, "ceil",  ["x"], [numberType()], numberType(), "ms_ceil", "");
	definePreludeFn(table, "abs",   ["x"], [numberType()], numberType(), "ms_abs", "");
	definePreludeFn(table, "min",   ["a", "b"], [numberType(), numberType()], numberType(), "ms_min", "");
	definePreludeFn(table, "max",   ["a", "b"], [numberType(), numberType()], numberType(), "ms_max", "");
	definePreludeFn(table, "sqrt",  ["x"], [numberType()], numberType(), "ms_sqrt", "");
	definePreludeFn(table, "round", ["x"], [numberType()], numberType(), "ms_round", "");

	// Conversion
	definePreludeFn(table, "toString",   ["value"], [numberType()],  stringType(),  "ms_to_string", "");
	definePreludeFn(table, "parseInt",   ["s"],     [stringType()],  numberType(),  "ms_parse_int", "");
	definePreludeFn(table, "parseFloat", ["s"],     [stringType()],  numberType(),  "ms_parse_float", "");

	// Assertions
	definePreludeFn(table, "assert", ["condition"], [booleanType()], voidType(), "ms_assert", "");
	definePreludeFn(table, "panic",  ["msg"],       [stringType()],  voidType(), "ms_panic", "");

	// String builtins
	definePreludeFn(table, "len", ["s"], [stringType()], numberType(), "", "LengthStr");
}

export function isPreludePath(path: string): boolean {
	return path === "std/core" || path === "std/core.ms";
}

// ===== Tests =====

testGroup("Prelude", () => {
	test("injectPrelude adds symbols", () => {
		const table = createSymbolTable();
		injectPrelude(table);
		check(lookupSymbol(table, "print") !== null);
		check(lookupSymbol(table, "println") !== null);
		check(lookupSymbol(table, "floor") !== null);
		check(lookupSymbol(table, "ceil") !== null);
		check(lookupSymbol(table, "abs") !== null);
		check(lookupSymbol(table, "min") !== null);
		check(lookupSymbol(table, "max") !== null);
		check(lookupSymbol(table, "sqrt") !== null);
		check(lookupSymbol(table, "round") !== null);
		check(lookupSymbol(table, "toString") !== null);
		check(lookupSymbol(table, "parseInt") !== null);
		check(lookupSymbol(table, "parseFloat") !== null);
		check(lookupSymbol(table, "assert") !== null);
		check(lookupSymbol(table, "panic") !== null);
		check(lookupSymbol(table, "len") !== null);
	});

	test("print has Function type", () => {
		const table = createSymbolTable();
		injectPrelude(table);
		const sym = lookupSymbol(table, "print");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
		check(sym.symbolType.typeReturn.kind === TypeKind.Void);
		check(sym.symbolType.typeChildren.length === 1);
		check(sym.symbolType.typeChildren[0].kind === TypeKind.String);
	});

	test("floor has runtimeName", () => {
		const table = createSymbolTable();
		injectPrelude(table);
		const sym = lookupSymbol(table, "floor");
		check(sym !== null);
		check(sym.runtimeName === "ms_floor");
		check(sym.builtinKind === "");
	});

	test("len has builtinKind", () => {
		const table = createSymbolTable();
		injectPrelude(table);
		const sym = lookupSymbol(table, "len");
		check(sym !== null);
		check(sym.builtinKind === "LengthStr");
		check(sym.runtimeName === "");
	});

	test("min has 2 params", () => {
		const table = createSymbolTable();
		injectPrelude(table);
		const sym = lookupSymbol(table, "min");
		check(sym !== null);
		check(sym.symbolType.typeChildren.length === 2);
		check(sym.symbolType.typeNames.length === 2);
	});

	test("user scope shadows prelude", () => {
		const table = createSymbolTable();
		injectPrelude(table);
		// Open child scope for user code
		openScope(table, ScopeKind.Module);
		const userSym = makeSymbol("print", SymbolKind.Variable, stringType(), false);
		defineSymbol(table, userSym);
		// Lookup finds user's print (string), not prelude's (function)
		const found = lookupSymbol(table, "print");
		check(found !== null);
		check(found.symbolType.kind === TypeKind.String);
		// Close module scope — prelude print restored
		closeScope(table);
		const restored = lookupSymbol(table, "print");
		check(restored !== null);
		check(restored.symbolType.kind === TypeKind.Function);
	});

	test("isPreludePath", () => {
		check(isPreludePath("std/core"));
		check(isPreludePath("std/core.ms"));
		check(!isPreludePath("std/testing"));
		check(!isPreludePath("./foo"));
	});
});
