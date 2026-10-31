@wasm
export function sumF(xs: Readonly<Span<float32>>): float32 {
	let s: float32 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function scaleI(xs: Span<int32>, k: int32): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] * k;
}

@wasm
export function flipB(bs: Span<boolean>): void {
	for (let i = 0; i < bs.length; i += 1) bs[i] = !bs[i];
}

@wasm
export function liftH(xs: Span<int16>): void {
	for (let i = 0; i < xs.length; i += 1) {
		const t: int32 = (xs[i] as int32) + 1000;
		xs[i] = t as int16;
	}
}

@wasm
export function quarterThrough(cb: (xs: Span<float32>) => void): float32 {
	let xs: Vec<float32> = [1, 2, 3, 4];
	cb(xs[0..3]);
	let s: float32 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function shiftThrough(cb: (xs: Span<int16>) => void): int32 {
	let xs: Vec<int16> = [10, 20, 30];
	cb(xs);
	return (xs[0] as int32) + (xs[1] as int32) + (xs[2] as int32);
}
