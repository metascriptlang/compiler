// Transform Context — shared state across all transforms

import { CheckerContext, addError, newSym, stampItem, createContext } from "../checker/context";
import { Type, Symbol, SymbolKind, SymbolState, SourceLocation } from "../ast/node";
import { makeSymbol, setFlag, hasFlag, SymbolFlag } from "../checker/symbol";
import { noneType } from "../checker/types";
import { WriteSummaries } from "../analyzer/writeEffects";

// Pending tuple type entry — collected by operatorLower, consumed by destructorLifting.
export interface PendingTupleOp {
	tupleType: Type;
	tupleName: string;
	ops: string[];  // which ops needed: "Lt", "Le"
}

export enum ModuleFact {
	Async,
	Await,
	Generator,
	Spawn,
	Defer,
	OptionalChain,
	Nullish,
	Spread,
	Switch,
}

export class TransformContext {
	tempCounter: number;
	errors: string[];
	checkerCtx: CheckerContext;  // type info from Phase 2 (null in test mode)
	jsBackend: boolean;
	raiserBackend: boolean;
	reloadableModules: string[];
	rangeChecks: boolean;
	boundChecks: boolean;
	objChecks: boolean;
	keepBuiltinMemberCalls: boolean;  // backend resolves builtins natively (opcodes / native methods) — keep member-call form instead of UFCS-rewriting to direct calls (mangled-name backends like C set false)
	pendingTupleOps: PendingTupleOp[];  // tuple ordering ops to generate (reference parity)
	pendingUnionEqs: Type[];  // payload unions compared by == on C
	cyclicCache: NameSet;     // canFormAcycle entry-level memo (types confirmed cyclic)
	acyclicCache: NameSet;    // canFormAcycle entry-level memo (types confirmed acyclic)
	splitLoopLocals: Symbol[];  // bindings of a loop body split at a yield: generatorLower hoists them to one slot for the whole loop
	actorImpls: HashMap<Symbol, Symbol>;  // actor method → its _impl handler (actor lowering emits async ones in lowerActorPre)
	jsEnumToStrings: EnumToStringCopy[];
	tdzFlags: HashMap<Symbol, Symbol>;  // module binding → its initialized flag (moduleTdz); every read and write inside a function is guarded by it
	liftTables: WriteSummaries | null;
	facts: BitSet<ModuleFact>;
	factsCollected: boolean;
}

export interface EnumToStringCopy {
	enumType: Type;
	fnSym: Symbol;
}

export function createTransformContext(): TransformContext {
	return { tempCounter: 0, errors: [], checkerCtx: null as unknown as CheckerContext, jsBackend: false, raiserBackend: false, reloadableModules: [], rangeChecks: true, boundChecks: true, objChecks: true, keepBuiltinMemberCalls: false, pendingTupleOps: [], pendingUnionEqs: [], cyclicCache: createNameSet(), acyclicCache: createNameSet(), splitLoopLocals: [], actorImpls: new HashMap<Symbol, Symbol>(), jsEnumToStrings: [], tdzFlags: new HashMap<Symbol, Symbol>(), liftTables: null, facts: 0 as BitSet<ModuleFact>, factsCollected: false };
}

export function createTransformContextWithChecker(cc: CheckerContext): TransformContext {
	const ctx = createTransformContext();
	ctx.checkerCtx = cc;
	return ctx;
}

export function noteFact(ctx: TransformContext, f: ModuleFact): void {
	ctx.facts = ctx.facts.incl(f);
}

export function mayContain(ctx: TransformContext, need: BitSet<ModuleFact>): boolean {
	return !ctx.factsCollected || !ctx.facts.isDisjointFrom(need);
}

export function reportTransformError(ctx: TransformContext, msg: string, loc: SourceLocation): void {
	if (ctx.checkerCtx != null) addError(ctx.checkerCtx, msg, loc.line, loc.column);
	else ctx.errors.push(msg);
}



// ===== NameSet =====
// Reusable string-name collector with contains/addUnique ops.
// NameSet: heap-allocated string set (class = pointer semantics).
// string[] arrays are passed by value in C (16-byte struct). When helper functions
// push to a NameSet parameter, the push would modify a LOCAL COPY if NameSet were
// a bare string[]. Using a class ensures mutations propagate through the call chain.
export class NameSet {
	items: string[];
	index: HashSet<string>;
}

export function createNameSet(): NameSet {
	return { items: [], index: new HashSet<string>() };
}

export function nameSetContains(ns: NameSet, name: string): boolean {
	return ns.index.has(name);
}

export function nameSetAdd(ns: NameSet, name: string): void {
	if (!ns.index.has(name)) {
		ns.index.add(name);
		ns.items.push(name);
	}
}

export function nameSetIntersect(a: NameSet, b: NameSet): NameSet {
	const result = createNameSet();
	for (const n of a.items) {
		if (nameSetContains(b, n)) {
			nameSetAdd(result, n);
		}
	}
	return result;
}

export class SymSet {
	items: Symbol[];
	index: HashSet<Symbol>;
}

export function createSymSet(): SymSet {
	return { items: [], index: new HashSet<Symbol>() };
}

export function symSetContains(ss: SymSet, sym: Symbol | null): boolean {
	return sym != null && ss.index.has(sym);
}

export function symSetAdd(ss: SymSet, sym: Symbol): void {
	if (!ss.index.has(sym)) {
		ss.index.add(sym);
		ss.items.push(sym);
	}
}

// Generate unique temp variable name: "$result_0", "$match_1", "$iter_2"
export function freshTemp(ctx: TransformContext, prefix: string): string {
	const n = ctx.tempCounter;
	ctx.tempCounter += 1;
	return "$" + prefix + "_" + n.toString();
}

export function mintSym(ctx: TransformContext, kind: SymbolKind, name: string, t: Type | null): Symbol {
	const sym = newSym(mintingChecker(ctx, name), kind, name, t);
	sym.state = SymbolState.Checked;
	setFlag(sym, SymbolFlag.Anon);
	return sym;
}

// Reference parity (getTemp): create a Symbol for a DRC temp variable.
// Returns a Symbol with declNode=null — safe to store on VarInfo (no destroy cascade).
export function freshTempSym(ctx: TransformContext, prefix: string, t: Type | null): Symbol {
	return mintSym(ctx, SymbolKind.Temp, freshTemp(ctx, prefix), t != null ? t : noneType());
}

// Owned long-lived synthetic local. Must NOT be $-prefixed: the DRC injector
// treats $-prefixed locals with identifier inits as transform-managed cursors
// (no copy/sink/destroy), which leaks any owned value parked in them.
export function freshOwnedSym(ctx: TransformContext, prefix: string, t: Type | null): Symbol {
	const n = ctx.tempCounter;
	ctx.tempCounter += 1;
	const name = "__" + prefix + "_" + n.toString();
	return newLoweredSym(ctx, SymbolKind.Variable, name, t != null ? t : noneType());
}

export function newLoweredSym(ctx: TransformContext, kind: SymbolKind, name: string, t: Type | null, mutable: boolean = false): Symbol {
	const sym = newSym(mintingChecker(ctx, name), kind, name, t);
	if (mutable) setFlag(sym, SymbolFlag.Mutable);
	return sym;
}

export function stampLoweredSym(ctx: TransformContext, sym: Symbol): Symbol {
	stampItem(mintingChecker(ctx, sym.name), sym);
	return sym;
}

export function mintingChecker(ctx: TransformContext, name: string): CheckerContext {
	if (ctx.checkerCtx == null) throw new Error(`internal: symbol '${name}' minted by a transform with no checker context`);
	return ctx.checkerCtx;
}

test "a name set keeps first-insertion order and ignores repeats" {
	const ns = createNameSet();
	nameSetAdd(ns, "b");
	nameSetAdd(ns, "a");
	nameSetAdd(ns, "b");
	assert ns.items.length == 2;
	assert ns.items[0] == "b";
	assert ns.items[1] == "a";
	assert nameSetContains(ns, "a");
	assert !nameSetContains(ns, "c");
}

test "a symbol set keys by identity, not by spelling, in first-insertion order" {
	const a = makeSymbol("x", SymbolKind.Variable, null, false);
	const b = makeSymbol("x", SymbolKind.Variable, null, false);
	const ss = createSymSet();
	symSetAdd(ss, b);
	symSetAdd(ss, a);
	symSetAdd(ss, b);
	assert ss.items.length == 2;
	assert ss.items[0] == b;
	assert symSetContains(ss, a);
	assert !symSetContains(ss, makeSymbol("x", SymbolKind.Variable, null, false));
	assert !symSetContains(ss, null);
}

test "a transform with no checker context refuses to mint a symbol" {
	const ctx = createTransformContext();
	let refused = "";
	try {
		freshTempSym(ctx, "t", null);
	} catch (e) {
		refused = (e as Error).message;
	}
	assert refused.includes("'$t_0' minted by a transform with no checker context"), refused;
}

test "symbols minted by a lowering take distinct ordinals from the checker context" {
	const ctx = createTransformContextWithChecker(createContext());
	const a = freshTempSym(ctx, "t", null);
	const b = freshOwnedSym(ctx, "t", null);
	const c = newLoweredSym(ctx, SymbolKind.Variable, "v", null, true);
	assert a.item > 0 && b.item > a.item && c.item > b.item;
	assert hasFlag(c, SymbolFlag.Mutable) && !hasFlag(b, SymbolFlag.Mutable);
}
