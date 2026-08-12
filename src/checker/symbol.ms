import { Node, NodeKind, ClassDeclData, ActorDeclData, Symbol, SymbolKind, SymbolState, makeLoc, Type, TypeKind } from "../ast/node";
import { noneType } from "./types";
import { IdentCache, createIdentCache, getIdentId } from "./idents";

function classStructTypeOf(classSym: Symbol): Type {
	let t = classSym.symbolType;
	if (t === null) return null as unknown as Type;
	if (t.kind === TypeKind.Ref && t.typeReturn !== null) t = t.typeReturn;
	return t;
}

function isClassBodyDecl(n: Node): boolean {
	if (n === null) return false;
	return n.kind === NodeKind.ClassDecl || n.kind === NodeKind.ActorDecl;
}

export function classDeclNodeOf(classSym: Symbol): Node {
	if (isClassBodyDecl(classSym.declNode)) return classSym.declNode;
	const t = classStructTypeOf(classSym);
	if (t === null || t.sym === null) return null as unknown as Node;
	if (isClassBodyDecl(t.sym.declNode)) return t.sym.declNode;
	return null as unknown as Node;
}

export function parentClassSymOf(classSym: Symbol): Symbol {
	const t = classStructTypeOf(classSym);
	if (t === null || t.typeExtra === null) return null as unknown as Symbol;
	let p = t.typeExtra;
	if (p.kind === TypeKind.Ref && p.typeReturn !== null) p = p.typeReturn;
	if (p.sym === null) return null as unknown as Symbol;
	return p.sym;
}

export function getCtorParamTypes(classSym: Symbol): Type[] {
	let sym = classSym;
	let depth = 0;
	while (sym !== null && depth < 64) {
		const decl = classDeclNodeOf(sym);
		if (decl === null) return null as unknown as Type[];
		let body: Node[] = null as unknown as Node[];
		if (decl.kind === NodeKind.ClassDecl) {
			body = (decl.data as ClassDeclData).classBody;
		} else if (decl.kind === NodeKind.ActorDecl) {
			body = (decl.data as ActorDeclData).actorBody;
		}
		if (body !== null) {
			for (const member of body) {
				if (member.kind === NodeKind.ConstructorDecl && member.nodeType !== null
						&& member.nodeType.kind === TypeKind.Function) {
					return member.nodeType.typeChildren;
				}
			}
		}
		sym = parentClassSymOf(sym);
		depth += 1;
	}
	return null as unknown as Type[];
}


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
	HasConstructor = 65536, // class has a ConstructorDecl → codegen calls ClassName_new()
	NativeMethod = 131072, // method from extern class — don't set ExtCall, keep as native member call
	GeneratedOp = 262144, // generated lifecycle hook (=destroy/=copy/=sink/=wasMoved) — skip DRC injection (reference parity: sfGeneratedOp)
	Nonisolated = 524288, // @nonisolated — actor field/method readable from outside (Swift parity)
	Consumed = 1048576, // PARALOCK Phase 1: affine-Promise binding (spawn-origin) has been awaited (affine consumption)
	OverloadSig = 2097152, // Tier 1: body-less overload signature — typecheck-only, codegen skips emission
	OverloadValidated = 4194304, // Tier 1: overload set already validated (return-type compatibility check)
	SinkTemp = 8388608, // DRC sink-arg temp synthesized by passCopyToSink — always single-use by construction, always last-read
	ComptimeNodeAlias = 16777216, // `const x = <jsx>` — x binds a compile-time Node, folded into the consuming macro; emits no runtime decl
	Imported = 33554432, // symbol imported from another module's export registry (importer-side copy)
	StaticLocal = 67108864, // `static` decl inside a body: carries Global (module storage) but is named per-site, since a body can hold several and a module may hold several bodies
}

// Flag helpers
export function hasFlag(sym: Symbol, flag: SymbolFlag): boolean {
	return (sym.symFlags & flag) !== 0;
}

export function setFlag(sym: Symbol, flag: SymbolFlag): void {
	sym.symFlags = sym.symFlags | flag;
}

// Mark a symbol as used (referenced).
// Also marks the enum type owner when an enum field is used.
export function markUsed(sym: Symbol): void {
	sym.symFlags = sym.symFlags | SymbolFlag.Used;
	if (sym.symbolType !== null && sym.symbolType.kind === TypeKind.Enum && sym.symbolType.sym !== null) {
		sym.symbolType.sym.symFlags = sym.symbolType.sym.symFlags | SymbolFlag.Used;
	}
}

// PARALOCK Phase 1: mark an affine-Promise binding as consumed (awaited).
// Also implies Used — a consumed binding has been referenced.
export function markConsumed(sym: Symbol): void {
	sym.symFlags = sym.symFlags | SymbolFlag.Consumed | SymbolFlag.Used;
}

// ===== Scope =====

export class Scope {
	// Ordered Map keyed by nameId — insertion order preserved, O(1) lookup.
	symbols: Map<int32, Symbol>;
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
	const global: Scope = { symbols: new Map<int32, Symbol>(), scopeKind: ScopeKind.Global, parent: null as unknown as Scope };
	return { current: global, allScopes: [global], identCache: createIdentCache() };
}

// Create with shared IdentCache (single IdentCache per compilation).
// All contexts sharing a cache get identical nameIds for the same string,
// eliminating cross-context nameId mismatch during generic instantiation.
export function createSymbolTableWithCache(cache: IdentCache): SymbolTable {
	const global: Scope = { symbols: new Map<int32, Symbol>(), scopeKind: ScopeKind.Global, parent: null as unknown as Scope };
	return { current: global, allScopes: [global], identCache: cache };
}

// ===== Scope Operations =====

export function openScope(table: SymbolTable, kind: ScopeKind): void {
	const scope: Scope = { symbols: new Map<int32, Symbol>(), scopeKind: kind, parent: table.current };
	table.allScopes.push(scope);
	table.current = scope;
}

// Add a Symbol to a Scope. First-insertion-wins: subsequent calls with the same
// nameId are no-ops (matches the prior linear-scan "first match" semantics of
// lookupSymbol). Caller must ensure sym.nameId is set (via getIdentId or
// defineSymbol which interns lazily).
export function addSymbolToScope(scope: Scope, sym: Symbol): void {
	if (sym.nameId === 0) return;
	if (!scope.symbols.has(sym.nameId)) {
		scope.symbols.set(sym.nameId, sym);
	}
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
	if (table.current.symbols.has(nameId)) {
		const existing = table.current.symbols.get(nameId);
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
	addSymbolToScope(table.current, sym);
	return Result.ok(true);
}

// ===== Symbol Lookup =====

// Walk scope chain, O(1) per scope via symbols index (populated by
// addSymbolToScope + defineSymbol). First-insertion-wins semantics match the
// prior linear-scan behavior.
export function lookupSymbol(table: SymbolTable, name: string): Symbol {
	const nameId = getIdentId(table.identCache, name);
	let scope = table.current;
	while (scope !== null) {
		const sym = scope.symbols.get(nameId);
		if (sym !== null) return sym;
		scope = scope.parent;
	}
	return null as unknown as Symbol;
}

// Check current scope only, O(1) via symbols.
export function lookupLocal(table: SymbolTable, name: string): Symbol {
	const nameId = getIdentId(table.identCache, name);
	const sym = table.current.symbols.get(nameId);
	if (sym !== null) return sym;
	return null as unknown as Symbol;
}

export function moduleScopeSymbols(table: SymbolTable): Symbol[] {
	let scope = table.current;
	while (scope !== null && scope.scopeKind !== ScopeKind.Module) {
		scope = scope.parent;
	}
	if (scope === null) return [];
	const out: Symbol[] = [];
	for (const sym of scope.symbols.values()) {
		out.push(sym);
	}
	return out;
}

// ===== Overload Helpers =====

export function hasOverloads(sym: Symbol): boolean {
	return sym.overloads.length > 0;
}

// ===== Helper: Create Symbol Shorthand =====

export function makeSymbol(name: string, kind: SymbolKind, symType: Type, mutable: boolean): Symbol {
	return makeSymbolState(name, kind, symType, mutable, SymbolState.Hollow);
}

export function makeSymbolState(name: string, kind: SymbolKind, symType: Type | null, mutable: boolean, state: SymbolState): Symbol {
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
	sym.jsModulePath = "";
	sym.overloadIdx = 0;
	sym.staticFields = [];
	sym.duVariantSlot = 0;
	return sym;
}

// Look up an exported symbol in Module / Global scopes. Uses symbols for
// O(1) per-scope lookup; verifies Exported flag on the found symbol (the map
// stores the first-inserted symbol per nameId, same as the prior linear scan
// would have returned first).
export function lookupExport(table: SymbolTable, name: string): Symbol {
	const nameId = getIdentId(table.identCache, name);
	let scope = table.current;
	while (scope !== null) {
		if (scope.scopeKind === ScopeKind.Module || scope.scopeKind === ScopeKind.Global) {
			const sym = scope.symbols.get(nameId);
			if (sym !== null && hasFlag(sym, SymbolFlag.Exported)) return sym;
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
	assert table.current.symbols.size === 0;
}

test "define and lookup" {
	const table = createSymbolTable();
	const sym = makeSymbol("x", SymbolKind.Variable, noneType(), false);
	const result = defineSymbol(table, sym);
	assert result.ok;
	assert lookupSymbol(table, "x") !== null;
	assert sym.state === SymbolState.Hollow;
}

test "duplicate error" {
	const table = createSymbolTable();
	const sym1 = makeSymbol("x", SymbolKind.Variable, noneType(), false);
	const sym2 = makeSymbol("x", SymbolKind.Variable, noneType(), true);
	defineSymbol(table, sym1);
	const result = defineSymbol(table, sym2);
	assert !result.ok;
}

test "scope nesting" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("a", SymbolKind.Variable, noneType(), false));
	openScope(table, ScopeKind.Block);
	defineSymbol(table, makeSymbol("b", SymbolKind.Variable, noneType(), false));
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
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, noneType(), false));
	openScope(table, ScopeKind.Block);
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, noneType(), true));
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
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, noneType(), false));
	openScope(table, ScopeKind.Block);
	// lookupLocal does NOT find parent scope
	assert lookupLocal(table, "x") === null;
	// lookupSymbol DOES find parent scope
	assert lookupSymbol(table, "x") !== null;
	closeScope(table);
}

test "function scope params" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("add", SymbolKind.Function, noneType(), false));
	openScope(table, ScopeKind.Function);
	defineSymbol(table, makeSymbol("a", SymbolKind.Parameter, noneType(), false));
	defineSymbol(table, makeSymbol("b", SymbolKind.Parameter, noneType(), false));
	assert lookupSymbol(table, "a") !== null;
	assert lookupSymbol(table, "b") !== null;
	assert lookupSymbol(table, "add") !== null;
	closeScope(table);
	assert lookupSymbol(table, "a") === null;
}

test "deeply nested" {
	const table = createSymbolTable();
	defineSymbol(table, makeSymbol("global", SymbolKind.Variable, noneType(), false));
	openScope(table, ScopeKind.Function);
	defineSymbol(table, makeSymbol("func", SymbolKind.Variable, noneType(), false));
	openScope(table, ScopeKind.Block);
	defineSymbol(table, makeSymbol("block", SymbolKind.Variable, noneType(), false));
	openScope(table, ScopeKind.Loop);
	defineSymbol(table, makeSymbol("loop", SymbolKind.Variable, noneType(), false));
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
	const sym1 = makeSymbol("add", SymbolKind.Function, noneType(), false);
	const sym2 = makeSymbol("add", SymbolKind.Function, noneType(), false);
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
	defineSymbol(table, makeSymbol("x", SymbolKind.Variable, noneType(), false));
	const r = defineSymbol(table, makeSymbol("x", SymbolKind.Variable, noneType(), false));
	assert !r.ok;
}

test "SymbolFlag.Exported default false" {
	const sym = makeSymbol("x", SymbolKind.Variable, noneType(), false);
	assert !hasFlag(sym, SymbolFlag.Exported);
}

test "lookupExport finds exported" {
	const table = createSymbolTable();
	openScope(table, ScopeKind.Module);
	const sym = makeSymbol("foo", SymbolKind.Function, noneType(), false);
	setFlag(sym, SymbolFlag.Exported);
	defineSymbol(table, sym);
	const found = lookupExport(table, "foo");
	assert found !== null;
	assert found.name === "foo";
}

test "lookupExport skips non-exported" {
	const table = createSymbolTable();
	openScope(table, ScopeKind.Module);
	defineSymbol(table, makeSymbol("bar", SymbolKind.Variable, noneType(), false));
	const found = lookupExport(table, "bar");
	assert found === null;
}
