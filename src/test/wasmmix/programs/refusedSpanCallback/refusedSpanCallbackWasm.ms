@wasm
export function mapInto(xs: Span<int32>, cb: (x: int32) => int32): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = cb(xs[i]);
}

@wasm
export function sumThen(xs: Readonly<Span<float32>>, cb: (total: float32) => void): void {
	let s: float32 = 0;
	for (const x of xs) s += x;
	cb(s);
}
