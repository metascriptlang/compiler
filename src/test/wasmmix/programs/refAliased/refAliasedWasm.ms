export struct Box { n: int32; label: string; }

@wasm
export function both(ref a: int32, ref b: int32): void {
	a = 1;
	b = b + 1;
}

@wasm
export function poke(ref n: int32, xs: Span<int32>): int32 {
	n = 5;
	return xs[0];
}

@wasm
export function nest(ref box: Box, ref n: int32): void {
	box.n = 1;
	n = n + 1;
}
