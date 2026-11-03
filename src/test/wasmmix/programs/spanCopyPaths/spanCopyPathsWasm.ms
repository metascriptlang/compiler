@wasm
export function bump(xs: Span<int32>): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] + 1;
}

@wasm
export function flip(bs: Span<boolean>): void {
	for (let i = 0; i < bs.length; i += 1) bs[i] = !bs[i];
}

@wasm
export function scale(xs: Span<float32>, k: float32): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] * k;
}

@wasm
export function countOn(bs: Vec<boolean>): int32 {
	let on = 0;
	for (const b of bs) if (b) on += 1;
	return on;
}

@wasm
export function sumOf(xs: Vec<int32>): int32 {
	let s = 0;
	for (const x of xs) s += x;
	return s;
}
