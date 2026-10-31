@wasm
export function scaleI(xs: Span<int32>, k: int32): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] * k;
}
