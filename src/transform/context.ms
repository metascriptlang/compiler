// Transform Context — shared state across all transforms

import { CheckerContext } from "../checker/context";
import { Node, Type } from "../ast/node";

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
	pendingTupleOps: PendingTupleOp[];  // tuple comparison ops to generate (reference parity)
}

export function createTransformContext(): TransformContext {
	return { tempCounter: 0, errors: [], fnDeclNames: [], checkerCtx: null as unknown as CheckerContext, jsBackend: false, pendingTupleOps: [] };
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
