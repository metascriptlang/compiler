// Transform Context — shared state across all transforms

export interface TransformContext {
	tempCounter: number;
	errors: string[];
}

export function createTransformContext(): TransformContext {
	return { tempCounter: 0, errors: [] };
}

// Generate unique temp variable name: "$result_0", "$match_1", "$iter_2"
export function freshTemp(ctx: TransformContext, prefix: string): string {
	const n = ctx.tempCounter;
	ctx.tempCounter += 1;
	return "$" + prefix + "_" + n.toString();
}
