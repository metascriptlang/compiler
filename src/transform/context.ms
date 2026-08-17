// Transform Context — shared state across all transforms

import { CheckerContext } from "../checker/context";
import { Type, Symbol, SymbolKind } from "../ast/node";
import { makeSymbol } from "../checker/symbol";
import { noneType } from "../checker/types";

// Pending tuple type entry — collected by operatorLower, consumed by destructorLifting.
export interface PendingTupleOp {
	tupleType: Type;
	tupleName: string;
	ops: string[];  // which ops needed: "eq", "lt", "le"
}

export class TransformContext {
	tempCounter: number;
	errors: string[];
	fnDeclNames: string[];  // collected function declaration names (for closureCallMarker)
	checkerCtx: CheckerContext;  // type info from Phase 2 (null in test mode)
	jsBackend: boolean;  // true = skip C-specific transforms (lambda lifting, destructor lifting, etc.)
	keepBuiltinMemberCalls: boolean;  // backend resolves builtins natively (opcodes / native methods) — keep member-call form instead of UFCS-rewriting to direct calls (mangled-name backends like C set false)
	pendingTupleOps: PendingTupleOp[];  // tuple comparison ops to generate (reference parity)
	pendingStructEqs: string[];  // struct/interface == uses to lift Eq for on-demand
	pendingCarrierEqs: Type[];   // synthesized carrier structs (Maybe<T>) compared by ==; carried as Type because they have no symbol-table entry to look the name up by
	cyclicCache: NameSet;     // canFormAcycle entry-level memo (types confirmed cyclic)
	acyclicCache: NameSet;    // canFormAcycle entry-level memo (types confirmed acyclic)
}

export function createTransformContext(): TransformContext {
	return { tempCounter: 0, errors: [], fnDeclNames: [], checkerCtx: null as unknown as CheckerContext, jsBackend: false, keepBuiltinMemberCalls: false, pendingTupleOps: [], pendingStructEqs: [], pendingCarrierEqs: [], cyclicCache: createNameSet(), acyclicCache: createNameSet() };
}

export function createTransformContextWithChecker(cc: CheckerContext): TransformContext {
	const ctx = createTransformContext();
	ctx.checkerCtx = cc;
	return ctx;
}



// ===== NameSet =====
// Reusable string-name collector with contains/addUnique ops.
// NameSet: heap-allocated string set (class = pointer semantics).
// string[] arrays are passed by value in C (16-byte struct). When helper functions
// push to a NameSet parameter, the push would modify a LOCAL COPY if NameSet were
// a bare string[]. Using a class ensures mutations propagate through the call chain.
export class NameSet {
	items: string[];
}

export function createNameSet(): NameSet {
	return { items: [] };
}

export function nameSetContains(ns: NameSet, name: string): boolean {
	for (const n of ns.items) {
		if (n === name) return true;
	}
	return false;
}

export function nameSetAdd(ns: NameSet, name: string): void {
	if (!nameSetContains(ns, name)) {
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

// Generate unique temp variable name: "$result_0", "$match_1", "$iter_2"
export function freshTemp(ctx: TransformContext, prefix: string): string {
	const n = ctx.tempCounter;
	ctx.tempCounter += 1;
	return "$" + prefix + "_" + n.toString();
}

// Reference parity (getTemp): create a Symbol for a DRC temp variable.
// Returns a Symbol with declNode=null — safe to store on VarInfo (no destroy cascade).
export function freshTempSym(ctx: TransformContext, prefix: string, t: Type | null): Symbol {
	const name = freshTemp(ctx, prefix);
	return makeSymbol(name, SymbolKind.Variable, t !== null ? t : noneType(), false);
}

// Owned long-lived synthetic local. Must NOT be $-prefixed: the DRC injector
// treats $-prefixed locals with identifier inits as transform-managed cursors
// (no copy/sink/destroy), which leaks any owned value parked in them.
export function freshOwnedSym(ctx: TransformContext, prefix: string, t: Type | null): Symbol {
	const n = ctx.tempCounter;
	ctx.tempCounter += 1;
	const name = "__" + prefix + "_" + n.toString();
	return makeSymbol(name, SymbolKind.Variable, t !== null ? t : noneType(), false);
}
