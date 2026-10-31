@wasm
export function sum(xs: Readonly<Span<float32>>): float32 {
	let s: float32 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function doubled(xs: Span<int32>): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] * 2;
}

@wasm
export function toggle(xs: Span<boolean>, at: int32): void {
	xs[at] = !xs[at];
}
