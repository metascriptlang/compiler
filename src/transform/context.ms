// Transform Context — shared state across all transforms

import { CheckerContext } from "../checker/context";

export interface TransformContext {
	tempCounter: number;
	errors: string[];
	fnDeclNames: string[];  // collected function declaration names (for closureCallMarker)
	checkerCtx: CheckerContext;  // type info from Phase 2 (null in test mode)
	jsBackend: boolean;  // true = skip C-specific transforms (lambda lifting, destructor lifting, etc.)
}

export function createTransformContext(): TransformContext {
	return { tempCounter: 0, errors: [], fnDeclNames: [], checkerCtx: null as unknown as CheckerContext, jsBackend: false };
}

export function createTransformContextWithChecker(cc: CheckerContext): TransformContext {
	const ctx = createTransformContext();
	ctx.checkerCtx = cc;
	return ctx;
}

// ===== NameSet =====
// Reusable string-name collector with contains/addUnique ops.
export type NameSet = string[];

export function nameSetContains(ns: NameSet, name: string): boolean {
	for (const n of ns) {
		if (n === name) return true;
	}
	return false;
}

export function nameSetAdd(ns: NameSet, name: string): void {
	if (!nameSetContains(ns, name)) {
		ns.push(name);
	}
}

export function nameSetIntersect(a: NameSet, b: NameSet): NameSet {
	const result: NameSet = [];
	for (const n of a) {
		if (nameSetContains(b, n)) {
			result.push(n);
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
