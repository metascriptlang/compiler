import { SourceLocation, Node, Symbol, SymbolKind, SymbolState, makeLoc, Type, TypeKind } from "../ast/node";
import { unknownType } from "./types";
import { IdentCache, createIdentCache, getIdentId } from "./idents";


// Result<T, E> is now available globally via prelude.
// In self-hosted source, we use it directly.

// ===== Scope Kind =====

export enum ScopeKind {
	Global, Module, Function, Block, Class, Loop,
}

// ===== Symbol Flags (Standard reference implementation parity) =====
// Bitfield for Symbol.symFlags — tracks declaration properties.
export enum SymbolFlag {
	None = 0,
	Used = 1,           // symbol is referenced somewhere
	Exported = 2,       // symbol is exported
	Mutable = 4,        // let/var/mutable
	Forward = 8,        // forward declaration (body not yet seen)
	NoSideEffect = 16,  // @pure — no side effects
	Global = 32,        // module-level variable
	ImportC = 64,       // extern declaration (extern ... from)
	CompileTime = 128,  // @comptime
	GcSafe = 256,       // no GC-unsafe operations
	WasForwarded = 512, // had forward decl, now has body
	Static = 1024,      // static class member or static linkage
	Sink = 2048,        // parameter takes ownership
	Lent = 4096,        // parameter is a borrow (no RC)
	NoReturn = 8192,    // function never returns (exit, abort, infinite loop)
	Async = 16384,      // async function (return type is Promise<T>)
	ParamMutated = 32768,  // parameter is mutated inside function body (blocks const-ptr promotion)
}

// Flag helpers
export function hasFlag(sym: Symbol, flag: SymbolFlag): boolean {
	return (sym.symFlags & flag) !== 0;
}

export function setFlag(sym: Symbol, flag: SymbolFlag): void {
	sym.symFlags = sym.symFlags | flag;
}

// ===== Scope =====

export class Scope {
	symbols: Symbol[];
	scopeKind: ScopeKind;
	parent: Ptr<Scope>;   // borrowed — allScopes owns all scopes
}

// ===== Symbol Table =====

export class SymbolTable {
	current: Ptr<Scope>;  // borrowed — allScopes owns all scopes
	allScopes: Scope[];
	identCache: IdentCache;
}

// ===== Constructors =====

export function createSymbolTable(): SymbolTable {
	const global: Scope = { symbols: [], scopeKind: ScopeKind.Global, parent: null as unknown as Scope };
	return { current: global, allScopes: [global], identCache: createIdentCache() };
}

// Create with shared IdentCache (single IdentCache per compilation).
// All contexts sharing a cache get identical nameIds for the same string,
// eliminating cross-context nameId mismatch during generic instantiation.
export function createSymbolTableWithCache(cache: IdentCache): SymbolTable {
	const global: Scope = { symbols: [], scopeKind: ScopeKind.Global, parent: null as unknown as Scope };
	return { current: global, allScopes: [global], identCache: cache };
}

// ===== Scope Operations =====

export function openScope(table: SymbolTable, kind: ScopeKind): void {
	const scope: Scope = { symbols: [], scopeKind: kind, parent: table.current };
	table.allScopes.push(scope);
	table.current = scope;
}

export function closeScope(table: SymbolTable): void {
	if (table.current.parent !== null) {
		table.current = table.current.parent;
	}
}

// ===== Symbol Registration =====

export function defineSymbol(table: SymbolTable, sym: Symbol): Result<boolean, string> {
	if (sym.nameId === 0) {
		sym.nameId = getIdentId(table.identCache, sym.name);
	}
	const nameId = sym.nameId;
	for (const existing of table.current.symbols) {
		if (existing.nameId === nameId) {
			// Allow function overloads: same name, both functions
			if (existing.symbolKind === SymbolKind.Function && sym.symbolKind === SymbolKind.Function) {
				// overloadIdx only disambiguates same-MODULE functions (module path handles cross-module).
				if (existing.modulePath === sym.modulePath) {
					sym.overloadIdx = existing.overloads.length + 1;
				}
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
	const nameId = getIdentId(table.identCache, name);
	let scope = table.current;
	while (scope !== null) {
		for (const sym of scope.symbols) {
			if (sym.nameId === nameId) {
				return sym;
			}
		}
		scope = scope.parent;
	}
	return null as unknown as Symbol;
}

// Check current scope only, return Symbol or null
export function lookupLocal(table: SymbolTable, name: string): Symbol {
	const nameId = getIdentId(table.identCache, name);
	for (const sym of table.current.symbols) {
		if (sym.nameId === nameId) {
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
	return makeSymbolState(name, kind, symType, mutable, SymbolState.Hollow);
}

export function makeSymbolState(name: string, kind: SymbolKind, symType: Type, mutable: boolean, state: SymbolState): Symbol {
	const sym = new Symbol();
	sym.name = name;
	sym.nameId = 0;
	sym.symbolKind = kind;
	sym.symbolType = symType;
	sym.state = state;
	sym.location = makeLoc(0, 0);
	sym.declNode = null as unknown as Node;
	sym.overloads = [];
	sym.nativeName = "";
	sym.builtinKind = "";
	sym.defaultParams = [];
	sym.symFlags = mutable ? SymbolFlag.Mutable : SymbolFlag.None;
	sym.modulePath = "";
	sym.originalName = "";
	sym.headerPath = "";
	sym.overloadIdx = 0;
	sym.staticFields = [];
	return sym;
}

// Look up an exported symbol in the table (searches Module and Global scopes)
export function lookupExport(table: SymbolTable, name: string): Symbol {
	const nameId = getIdentId(table.identCache, name);
	let scope = table.current;
	while (scope !== null) {
		if (scope.scopeKind === ScopeKind.Module || scope.scopeKind === ScopeKind.Global) {
			for (const sym of scope.symbols) {
				if (sym.nameId === nameId && hasFlag(sym, SymbolFlag.Exported)) return sym;
			}
		}
		scope = scope.parent;
	}
	return null as unknown as Symbol;
}

// isPointerType — Ref/Ptr are pointer types, Objects are always value types
export function isPointerType(t: Type, table: SymbolTable): boolean {
	return t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr;
}

// ===== Tests =====
test "create table" {
	const table = createSymbolTable();
	assert table.current.scopeKind === ScopeKind.Global;
	assert table.current.symbols.length === 0;
}

test "define and lookup" {
	const table = createSymbolTable();
	const sym = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
	const result = defineSymbol(table, sym);
	assert result.ok;
	assert lookupSymbol(table, "x") !== null;
	assert sym.state === SymbolState.Hollow;
}

test "duplicate error" {
	const table = createSymbolTable();
	const sym1 = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
	const sym2 = makeSymbol("x", SymbolKind.Variable, unknownType(), true);
	defineSymbol(table, sym1);
	const result = defineSymbol(table, sym2);
	assert !result.ok;
}

test "scope nesting" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("a", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Block);
	defineSymbol(table, makeSymbol("b", SymbolKind.Variable, unknownType(), false));
	// Inner scope sees both
	assert lookupSymbol(table, "a") !== null;
	assert lookupSymbol(table, "b") !== null;
	closeScope(table);
	// Outer scope sees only a
	assert lookupSymbol(table, "a") !== null;
	assert lookupSymbol(table, "b") === null;
}

test "shadowing" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Block);
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), true));
	// Inner lookup finds inner (mutable) shadow
	const inner = lookupSymbol(table, "x");
	assert inner !== null;
	assert hasFlag(inner, SymbolFlag.Mutable);
	closeScope(table);
	// Outer lookup finds outer (immutable) original
	const outer = lookupSymbol(table, "x");
	assert outer !== null;
	assert !hasFlag(outer, SymbolFlag.Mutable);
}

test "lookupLocal" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
	openScope(table, ScopeKind.Block);
	// lookupLocal does NOT find parent scope
	assert lookupLocal(table, "x") === null;
	// lookupSymbol DOES find parent scope
	assert lookupSymbol(table, "x") !== null;
	closeScope(table);
}

test "function scope params" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("add", SymbolKind.Function, unknownType(), false));
	openScope(table, ScopeKind.Function);
	defineSymbol(table, makeSymbol("a", SymbolKind.Parameter, unknownType(), false));
	defineSymbol(table, makeSymbol("b", SymbolKind.Parameter, unknownType(), false));
	assert lookupSymbol(table, "a") !== null;
	assert lookupSymbol(table, "b") !== null;
	assert lookupSymbol(table, "add") !== null;
	closeScope(table);
	assert lookupSymbol(table, "a") === null;
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
	assert lookupSymbol(table, "global") !== null;
	assert lookupSymbol(table, "func") !== null;
	assert lookupSymbol(table, "block") !== null;
	assert lookupSymbol(table, "loop") !== null;
	closeScope(table);
	closeScope(table);
	closeScope(table);
	assert lookupSymbol(table, "loop") === null;
}

test "scope kind" {
	const table = createSymbolTable();
	assert table.current.scopeKind === ScopeKind.Global;
	openScope(table, ScopeKind.Function);
	assert table.current.scopeKind === ScopeKind.Function;
	openScope(table, ScopeKind.Loop);
	assert table.current.scopeKind === ScopeKind.Loop;
	closeScope(table);
	closeScope(table);
}

test "function overloads allowed" {
	const table = createSymbolTable();
	const sym1 = makeSymbol("add", SymbolKind.Function, unknownType(), false);
	const sym2 = makeSymbol("add", SymbolKind.Function, unknownType(), false);
	const r1 = defineSymbol(table, sym1);
	assert r1.ok;
	const r2 = defineSymbol(table, sym2);
	assert r2.ok;  // no error for function overload
	const found = lookupSymbol(table, "add");
	assert found !== null;
	assert found.overloads.length === 1;
}

test "non-function duplicate still errors" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
	const r = defineSymbol(table, makeSymbol("x", SymbolKind.Variable, unknownType(), false));
	assert !r.ok;
}

test "SymbolFlag.Exported default false" {
	const sym = makeSymbol("x", SymbolKind.Variable, unknownType(), false);
	assert !hasFlag(sym, SymbolFlag.Exported);
}

test "lookupExport finds exported" {
	const table = createSymbolTable();
	openScope(table, ScopeKind.Module);
	const sym = makeSymbol("foo", SymbolKind.Function, unknownType(), false);
	setFlag(sym, SymbolFlag.Exported);
	defineSymbol(table, sym);
	const found = lookupExport(table, "foo");
	assert found !== null;
	assert found.name === "foo";
}

test "lookupExport skips non-exported" {
	const table = createSymbolTable();
	openScope(table, ScopeKind.Module);
	defineSymbol(table, makeSymbol("bar", SymbolKind.Variable, unknownType(), false));
	const found = lookupExport(table, "bar");
	assert found === null;
}
