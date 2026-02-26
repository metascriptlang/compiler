// Transform Context — shared state across all transforms

import { CheckerContext } from "../checker/context";

export interface TransformContext {
	tempCounter: number;
	errors: string[];
	fnDeclNames: string[];  // collected function declaration names (for closureCallMarker)
	checkerCtx: CheckerContext;  // type info from Phase 2 (null in test mode)
}

export function createTransformContext(): TransformContext {
	return { tempCounter: 0, errors: [], fnDeclNames: [], checkerCtx: null as unknown as CheckerContext };
}

export function createTransformContextWithChecker(cc: CheckerContext): TransformContext {
	const ctx = createTransformContext();
	ctx.checkerCtx = cc;
	return ctx;
}

// ===== NameSet =====
// Reusable string-name collector with contains/addUnique ops.
// Wraps string[] in interface to avoid DRC value-type gotcha (#4).

export interface NameSet {
	names: string[];
}

export function nameSetContains(ns: NameSet, name: string): boolean {
	for (const n of ns.names) {
		if (n === name) return true;
	}
	return false;
}

export function nameSetAdd(ns: NameSet, name: string): void {
	if (!nameSetContains(ns, name)) {
		ns.names.push(name);
	}
}

// Generate unique temp variable name: "$result_0", "$match_1", "$iter_2"
export function freshTemp(ctx: TransformContext, prefix: string): string {
	const n = ctx.tempCounter;
	ctx.tempCounter += 1;
	return "$" + prefix + "_" + n.toString();
}
