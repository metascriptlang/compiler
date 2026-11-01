@wasm
export function copyUp(dst: Span<int32>, src: Readonly<Span<int32>>): void {
	for (let i = 0; i < dst.length; i += 1) dst[i] = src[i];
}

@wasm
export function stamp(a: Span<int32>, b: Span<int32>): void {
	b[0] = 9;
	a[1] = 7;
}

@wasm
export function pairHead(a: Readonly<Span<int32>>, b: Readonly<Span<int32>>): int32 {
	return a[0] * 10 + b[0];
}

@wasm
export function chain(a: Span<int32>, b: Span<int32>, c: Span<int32>): void {
	a[1] += 5;
	b[2] = b[0] + 1;
	c[1] = c[0] + 1;
}

@wasm
export function flipAfter(all: Readonly<Span<boolean>>, part: Span<boolean>): int32 {
	part[0] = !part[0];
	let on = 0;
	for (let i = 0; i < all.length; i += 1) if (all[i]) on += 1;
	return on;
}

@wasm
export function countAfter(all: Vec<boolean>, part: Span<boolean>): int32 {
	if (part.length > 0) part[0] = !part[0];
	let on = 0;
	for (const b of all) if (b) on += 1;
	return on;
}

@wasm
export function smear(cb: (dst: Span<float64>, src: Readonly<Span<float64>>) => void): float64 {
	let v: Vec<float64> = [10, 2, 3, 4];
	cb(v[1..4], v[0..3]);
	return v[3];
}
