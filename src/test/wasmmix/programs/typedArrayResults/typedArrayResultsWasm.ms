@wasm
export function rampF(n: int32): Float32Array {
	const out = new Float32Array(n);
	for (let i = 0; i < n; i += 1) out[i] = (i as float32) + 0.5;
	return out;
}

@wasm
export function rampI(n: int32): Int32Array {
	const out = new Int32Array(n);
	for (let i = 0; i < n; i += 1) out[i] = -i * 1000;
	return out;
}

@wasm
export function levels(n: int32): Uint8ClampedArray {
	const out = new Uint8ClampedArray(n);
	for (let i = 0; i < n; i += 1) out[i] = (i * 100) as uint8;
	return out;
}

@wasm
export function wide(n: int32): Float64Array {
	const out = new Float64Array(n);
	for (let i = 0; i < n; i += 1) out[i] = (i as float64) / 4;
	return out;
}

@wasm
export function maybe(n: int32): Int16Array | null {
	if (n == 0) return null;
	const out = new Int16Array(n);
	out[0] = -7;
	return out;
}

@wasm
export function middle(n: int32): Float32Array {
	const big = new Float32Array(n + 4);
	for (let i = 0; i < n + 4; i += 1) big[i] = i as float32;
	return big.subarray(2, 2 + n);
}

@wasm
export function empty(): Uint16Array {
	return new Uint16Array(0);
}

@wasm
export function sumIn(xs: Readonly<Span<float32>>): float32 {
	let s: float32 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function scaleIn(xs: Span<float32>, k: float32): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] * k;
}
