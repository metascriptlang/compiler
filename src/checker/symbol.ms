import { SourceLocation } from "../ast/node";
import { Type, TypeKind, unknownType } from "./types";
import { test, check, testGroup } from "std/testing";

// ===== Symbol Kind =====

export enum SymbolKind {
	Variable, Function, Class, Interface,
	TypeAlias, Enum, Parameter, Property, Method,
}

// ===== Scope Kind =====

export enum ScopeKind {
	Global, Module, Function, Block, Class, Loop,
}

// ===== Symbol =====

export interface Symbol {
	name: string;
	symbolKind: SymbolKind;
	symbolType: Type;
	isMutable: boolean;
	isExported: boolean;
	location: SourceLocation;
	overloads: Symbol[];    // non-empty when function has overloads
	runtimeName: string;    // @runtime("c_name") → "c_name", else ""
	builtinKind: string;    // @builtin("Name") → "Name", else ""
}

// ===== Scope =====

export interface Scope {
	symbols: Symbol[];
	scopeKind: ScopeKind;
	parent: Scope;   // null for global scope
}

// ===== Symbol Table =====

export interface SymbolTable {
	current: Scope;
}

// ===== Constructors =====

export function createSymbolTable(): SymbolTable {
	const global: Scope = { symbols: [], scopeKind: ScopeKind.Global, parent: null as unknown as Scope };
	return { current: global };
}

// ===== Scope Operations =====

export function openScope(table: SymbolTable, kind: ScopeKind): void {
	const scope: Scope = { symbols: [], scopeKind: kind, parent: table.current };
	table.current = scope;
}

export function closeScope(table: SymbolTable): void {
	if (table.current.parent !== null) {
		table.current = table.current.parent;
	}
}

// ===== Symbol Registration =====

export function defineSymbol(table: SymbolTable, sym: Symbol): Result<boolean, string> {
	for (const existing of table.current.symbols) {
		if (existing.name === sym.name) {
			// Allow function overloads: same name, both functions
			if (existing.symbolKind === SymbolKind.Function && sym.symbolKind === SymbolKind.Function) {
				existing.overloads.push(sym);
				return Result.ok(true);
			}
			return Result.err(`Duplicate symbol '${sym.name}'`);
		}
	}
	table.current.symbols.push(sym);
	return Result.ok(true);
}

// ===== Symbol Lookup =====

// Walk scope chain, return Symbol or null
export function lookupSymbol(table: SymbolTable, name: string): Symbol {
	let scope = table.current;
	while (scope !== null) {
		for (const sym of scope.symbols) {
			if (sym.name === name) {
				return sym;
			}
		}
		scope = scope.parent;
	}
	return null as unknown as Symbol;
}

// Check current scope only, return Symbol or null
export function lookupLocal(table: SymbolTable, name: string): Symbol {
	for (const sym of table.current.symbols) {
		if (sym.name === name) {
			return sym;
		}
	}
	return null as unknown as Symbol;
}

// ===== Overload Helpers =====

export function hasOverloads(sym: Symbol): boolean {
	return sym.overloads.length > 0;
}

// ===== Helper: Create Symbol Shorthand =====

export function makeSymbol(name: string, kind: SymbolKind, symType: Type, mutable: boolean): Symbol {
	return {
		name,
		symbolKind: kind,
		symbolType: symType,
		isMutable: mutable,
		isExported: false,
		location: { line: 0, column: 0 },
		overloads: [],
		runtimeName: "",
		builtinKind: "",
	};
}

// Look up an exported symbol in the table (searches Module and Global scopes)
export function lookupExport(table: SymbolTable, name: string): Symbol {
	let scope = table.current;
	while (scope !== null) {
		if (scope.scopeKind === ScopeKind.Module || scope.scopeKind === ScopeKind.Global) {
			for (const sym of scope.symbols) {
				if (sym.name === name && sym.isExported) return sym;
			}
		}
		scope = scope.parent;
	}
	return null as unknown as Symbol;
}

// isPointerType — used by destructorLifting and analyzer/classify for RC classification
export function isPointerType(t: Type, table: SymbolTable): boolean {
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) return true;
	if (t.kind !== TypeKind.Object || t.typeName === "") return false;
	const sym = lookupSymbol(table, t.typeName);
	if (sym === null) return false;
	return sym.symbolKind === SymbolKind.Interface || sym.symbolKind === SymbolKind.Class;
}

// ===== Tests =====

testGroup("SymbolTable", () => {
	test("create table", () => {
		const table = createSymbolTable();
		check(table.current.scopeKind === ScopeKind.Global);
		check(table.current.symbols.length === 0);
	});
	test("define and lookup", () => {
		const table = createSymbolTable();
		const sym = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
		const result = defineSymbol(table, sym);
		check(result.ok);
		check(lookupSymbol(table, "x") !== null);
	});
	test("duplicate error", () => {
		const table = createSymbolTable();
		const sym1 = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
		const sym2 = makeSymbol("x", SymbolKind.Variable, unknownType(), true);
		defineSymbol(table, sym1);
		const result = defineSymbol(table, sym2);
		check(!result.ok);
	});
	test("scope nesting", () => {
		const table = createSymbolTable();
		defineSymbol(table, makeSymbol("a", SymbolKind.Variable, unknownType(), false));
		openScope(table, ScopeKind.Block);
		defineSymbol(table, makeSymbol("b", SymbolKind.Variable, unknownType(), false));
		// Inner scope sees both
		check(lookupSymbol(table, "a") !== null);
		check(lookupSymbol(table, "b") !== null);
		closeScope(table);
		// Outer scope sees only a
		check(lookupSymbol(table, "a") !== null);
		check(lookupSymbol(table, "b") === null);
	});
	test("shadowing", () => {
		const table = createSymbolTable();
		defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
		openScope(table, ScopeKind.Block);
		defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), true));
		// Inner lookup finds inner (mutable) shadow
		const inner = lookupSymbol(table, "x");
		check(inner !== null);
		check(inner.isMutable === true);
		closeScope(table);
		// Outer lookup finds outer (immutable) original
		const outer = lookupSymbol(table, "x");
		check(outer !== null);
		check(outer.isMutable === false);
	});
	test("lookupLocal", () => {
		const table = createSymbolTable();
		defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
		openScope(table, ScopeKind.Block);
		// lookupLocal does NOT find parent scope
		check(lookupLocal(table, "x") === null);
		// lookupSymbol DOES find parent scope
		check(lookupSymbol(table, "x") !== null);
		closeScope(table);
	});
	test("function scope params", () => {
		const table = createSymbolTable();
		defineSymbol(table, makeSymbol("add", SymbolKind.Function, unknownType(), false));
		openScope(table, ScopeKind.Function);
		defineSymbol(table, makeSymbol("a", SymbolKind.Parameter, unknownType(), false));
		defineSymbol(table, makeSymbol("b", SymbolKind.Parameter, unknownType(), false));
		check(lookupSymbol(table, "a") !== null);
		check(lookupSymbol(table, "b") !== null);
		check(lookupSymbol(table, "add") !== null);
		closeScope(table);
		check(lookupSymbol(table, "a") === null);
	});
	test("deeply nested", () => {
		const table = createSymbolTable();
		defineSymbol(table, makeSymbol("global", SymbolKind.Variable, unknownType(), false));
		openScope(table, ScopeKind.Function);
		defineSymbol(table, makeSymbol("func", SymbolKind.Variable, unknownType(), false));
		openScope(table, ScopeKind.Block);
		defineSymbol(table, makeSymbol("block", SymbolKind.Variable, unknownType(), false));
		openScope(table, ScopeKind.Loop);
		defineSymbol(table, makeSymbol("loop", SymbolKind.Variable, unknownType(), false));
		check(lookupSymbol(table, "global") !== null);
		check(lookupSymbol(table, "func") !== null);
		check(lookupSymbol(table, "block") !== null);
		check(lookupSymbol(table, "loop") !== null);
		closeScope(table);
		closeScope(table);
		closeScope(table);
		check(lookupSymbol(table, "loop") === null);
	});
	test("scope kind", () => {
		const table = createSymbolTable();
		check(table.current.scopeKind === ScopeKind.Global);
		openScope(table, ScopeKind.Function);
		check(table.current.scopeKind === ScopeKind.Function);
		openScope(table, ScopeKind.Loop);
		check(table.current.scopeKind === ScopeKind.Loop);
		closeScope(table);
		closeScope(table);
	});
	test("function overloads allowed", () => {
		const table = createSymbolTable();
		const sym1 = makeSymbol("add", SymbolKind.Function, unknownType(), false);
		const sym2 = makeSymbol("add", SymbolKind.Function, unknownType(), false);
		const r1 = defineSymbol(table, sym1);
		check(r1.ok);
		const r2 = defineSymbol(table, sym2);
		check(r2.ok);  // no error for function overload
		const found = lookupSymbol(table, "add");
		check(found !== null);
		check(found.overloads.length === 1);
	});
	test("non-function duplicate still errors", () => {
		const table = createSymbolTable();
		defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
		const r = defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
		check(!r.ok);
	});
	test("isExported default false", () => {
		const sym = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
		check(!sym.isExported);
	});
	test("lookupExport finds exported", () => {
		const table = createSymbolTable();
		openScope(table, ScopeKind.Module);
		const sym = makeSymbol("foo", SymbolKind.Function, unknownType(), false);
		sym.isExported = true;
		defineSymbol(table, sym);
		const found = lookupExport(table, "foo");
		check(found !== null);
		check(found.name === "foo");
	});
	test("lookupExport skips non-exported", () => {
		const table = createSymbolTable();
		openScope(table, ScopeKind.Module);
		defineSymbol(table, makeSymbol("bar", SymbolKind.Variable, unknownType(), false));
		const found = lookupExport(table, "bar");
		check(found === null);
	});
});
