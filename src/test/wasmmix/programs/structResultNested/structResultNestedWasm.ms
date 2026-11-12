export struct Pair {
	a: int32;
	b: int32;
}

export struct Wide {
	big: int64;
	neg: int32;
	ratio: float32;
	on: boolean;
	top: uint32;
}

@wasm
export function shift(p: Pair, by: int32): Pair {
	return { a: p.a + by, b: p.b + by };
}

@wasm
export function viaCallback(p: Pair, visit: (n: int32) => int32): Pair {
	const by = visit(p.a);
	return { a: p.a + by, b: p.b + by };
}

@wasm
export function maybe(p: Pair, some: boolean): Pair | null {
	return some ? p : null;
}

@wasm
export function wide(seed: int32): Wide {
	return { big: -9007199254740993, neg: -seed, ratio: 2.5, on: true, top: 4294967295 };
}
