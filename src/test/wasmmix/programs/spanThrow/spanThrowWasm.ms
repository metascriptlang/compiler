@wasm
export function editThrough(xs: Span<int32>, cb: (v: Span<int32>) => void): void {
	xs[0] = 100;
	cb(xs);
	xs[2] = 300;
}

@wasm
export function stampThrough(bs: Span<boolean>, cb: (at: int32) => void): int32 {
	bs[0] = true;
	cb(1);
	bs[1] = true;
	return 1;
}

@wasm
export function halveThrough(xs: Span<float32>, k: int32, cb: (v: Span<float32>, at: int32) => void): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] / 2;
	cb(xs, k);
	xs[0] = -1;
}
