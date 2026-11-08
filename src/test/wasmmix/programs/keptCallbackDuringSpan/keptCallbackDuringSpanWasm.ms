let kept: (n: int32) => void = (n: int32): void => {};

@wasm
export function listen(visit: (n: int32) => void): void {
	kept = visit;
}

@wasm
export function bump(xs: Span<int32>): void {
	xs[0] = xs[0] + 1;
	kept(xs[0]);
}

@wasm
export function forget(): void {
	kept = (n: int32): void => {};
}
