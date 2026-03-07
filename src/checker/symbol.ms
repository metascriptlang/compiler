import { SourceLocation, Node, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { Type, TypeKind, unknownType } from "./types";


// Re-export from ast/node (unified Symbol definition)
export { Symbol, SymbolKind, SymbolState } from "../ast/node";

// Result<T, E> is now available globally via prelude.
// In self-hosted source, we use it directly.

// ===== Scope Kind =====

export enum ScopeKind {
	Global, Module, Function, Block, Class, Loop,
}

// ===== Symbol Flags (Nim parity: TSymFlags) =====
// Bitfield for Symbol.symFlags — tracks declaration properties.
export const SF_NONE: number = 0;
export const SF_USED: number = 1;          // symbol is referenced somewhere
export const SF_EXPORTED: number = 2;      // symbol is exported
export const SF_MUTABLE: number = 4;       // let/var/mutable
export const SF_FORWARD: number = 8;       // forward declaration (body not yet seen)
export const SF_NO_SIDE_EFFECT: number = 16; // @pure — no side effects
export const SF_GLOBAL: number = 32;       // module-level variable
export const SF_IMPORT_C: number = 64;     // extern declaration (extern ... from)
export const SF_COMPILE_TIME: number = 128; // @comptime
export const SF_GC_SAFE: number = 256;     // no GC-unsafe operations
export const SF_WAS_FORWARDED: number = 512; // had forward decl, now has body
export const SF_STATIC: number = 1024;     // static class member or static linkage
export const SF_SINK: number = 2048;       // parameter takes ownership
export const SF_LENT: number = 4096;       // parameter is a borrow (no RC)

// Flag helpers
export function hasFlag(sym: Symbol, flag: number): boolean {
	return (sym.symFlags & flag) !== 0;
}

export function setFlag(sym: Symbol, flag: number): void {
	sym.symFlags = sym.symFlags | flag;
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
	const sym = new Symbol();
	sym.name = name;
	sym.symbolKind = kind;
	sym.symbolType = symType;
	sym.state = SymbolState.Hollow;
	sym.location = { line: 0, column: 0 };
	sym.declNode = null as unknown as Node;
	sym.overloads = [];
	sym.nativeName = "";
	sym.builtinKind = "";
	sym.defaultParamText = [];
	sym.symFlags = mutable ? SF_MUTABLE : SF_NONE;
	return sym;
}

// Look up an exported symbol in the table (searches Module and Global scopes)
export function lookupExport(table: SymbolTable, name: string): Symbol {
	let scope = table.current;
	while (scope !== null) {
		if (scope.scopeKind === ScopeKind.Module || scope.scopeKind === ScopeKind.Global) {
			for (const sym of scope.symbols) {
				if (sym.name === name && hasFlag(sym, SF_EXPORTED)) return sym;
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
	// Only classes are pointer types (heap-allocated, RC'd)
	// Interfaces are value-type structs — NOT pointers (D1 fix)
	const sym = lookupSymbol(table, t.typeName);
	if (sym === null) return false;
	return sym.symbolKind === SymbolKind.Class;
}

// ===== Tests =====
test "create table" {
	const table = createSymbolTable();
	expect(table.current.scopeKind === ScopeKind.Global);
	expect(table.current.symbols.length === 0);
}

test "define and lookup" {
	const table = createSymbolTable();
	const sym = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
	const result = defineSymbol(table, sym);
	expect(result.ok);
	expect(lookupSymbol(table, "x") !== null);
	expect(sym.state === SymbolState.Hollow);
}

test "duplicate error" {
	const table = createSymbolTable();
	const sym1 = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
	const sym2 = makeSymbol("x", SymbolKind.Variable, unknownType(), true);
	defineSymbol(table, sym1);
	const result = defineSymbol(table, sym2);
	expect(!result.ok);
}

test "scope nesting" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("a", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Block);
	defineSymbol(table, makeSymbol("b", SymbolKind.Variable, unknownType(), false));
	// Inner scope sees both
	expect(lookupSymbol(table, "a") !== null);
	expect(lookupSymbol(table, "b") !== null);
	closeScope(table);
	// Outer scope sees only a
	expect(lookupSymbol(table, "a") !== null);
	expect(lookupSymbol(table, "b") === null);
}

test "shadowing" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Block);
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), true));
	// Inner lookup finds inner (mutable) shadow
	const inner = lookupSymbol(table, "x");
	expect(inner !== null);
	expect(hasFlag(inner, SF_MUTABLE));
	closeScope(table);
	// Outer lookup finds outer (immutable) original
	const outer = lookupSymbol(table, "x");
	expect(outer !== null);
	expect(!hasFlag(outer, SF_MUTABLE));
}

test "lookupLocal" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Block);
	// lookupLocal does NOT find parent scope
	expect(lookupLocal(table, "x") === null);
	// lookupSymbol DOES find parent scope
	expect(lookupSymbol(table, "x") !== null);
	closeScope(table);
}

test "function scope params" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("add", SymbolKind.Function, unknownType(), false));
	openScope(table, ScopeKind.Function);
	defineSymbol(table, makeSymbol("a", SymbolKind.Parameter, unknownType(), false));
	defineSymbol(table, makeSymbol("b", SymbolKind.Parameter, unknownType(), false));
	expect(lookupSymbol(table, "a") !== null);
	expect(lookupSymbol(table, "b") !== null);
	expect(lookupSymbol(table, "add") !== null);
	closeScope(table);
	expect(lookupSymbol(table, "a") === null);
}

test "deeply nested" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("global", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Function);
	defineSymbol(table, makeSymbol("func", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Block);
	defineSymbol(table, makeSymbol("block", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Loop);
	defineSymbol(table, makeSymbol("loop", SymbolKind.Variable, unknownType(), false));
	expect(lookupSymbol(table, "global") !== null);
	expect(lookupSymbol(table, "func") !== null);
	expect(lookupSymbol(table, "block") !== null);
	expect(lookupSymbol(table, "loop") !== null);
	closeScope(table);
	closeScope(table);
	closeScope(table);
	expect(lookupSymbol(table, "loop") === null);
}

test "scope kind" {
	const table = createSymbolTable();
	expect(table.current.scopeKind === ScopeKind.Global);
	openScope(table, ScopeKind.Function);
	expect(table.current.scopeKind === ScopeKind.Function);
	openScope(table, ScopeKind.Loop);
	expect(table.current.scopeKind === ScopeKind.Loop);
	closeScope(table);
	closeScope(table);
}

test "function overloads allowed" {
	const table = createSymbolTable();
	const sym1 = makeSymbol("add", SymbolKind.Function, unknownType(), false);
	const sym2 = makeSymbol("add", SymbolKind.Function, unknownType(), false);
	const r1 = defineSymbol(table, sym1);
	expect(r1.ok);
	const r2 = defineSymbol(table, sym2);
	expect(r2.ok);  // no error for function overload
	const found = lookupSymbol(table, "add");
	expect(found !== null);
	expect(found.overloads.length === 1);
}

test "non-function duplicate still errors" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
	const r = defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
	expect(!r.ok);
}

test "SF_EXPORTED default false" {
	const sym = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
	expect(!hasFlag(sym, SF_EXPORTED));
}

test "lookupExport finds exported" {
	const table = createSymbolTable();
	openScope(table, ScopeKind.Module);
	const sym = makeSymbol("foo", SymbolKind.Function, unknownType(), false);
	setFlag(sym, SF_EXPORTED);
	defineSymbol(table, sym);
	const found = lookupExport(table, "foo");
	expect(found !== null);
	expect(found.name === "foo");
}

test "lookupExport skips non-exported" {
	const table = createSymbolTable();
	openScope(table, ScopeKind.Module);
	defineSymbol(table, makeSymbol("bar", SymbolKind.Variable, unknownType(), false));
	const found = lookupExport(table, "bar");
	expect(found === null);
}
