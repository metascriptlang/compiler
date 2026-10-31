@wasm
export function peekThen(xs: Span<int32>, cb: (first: int32) => void): void {
	cb(xs[0]);
}

@wasm
export function peekFlagThen(bs: Span<boolean>, cb: (first: boolean) => void): void {
	cb(bs[0]);
}

@wasm
export function doubleFirstThen(xs: Span<float64>, cb: (k: int32) => void): void {
	xs[0] = xs[0] * 2;
	cb(0);
}
