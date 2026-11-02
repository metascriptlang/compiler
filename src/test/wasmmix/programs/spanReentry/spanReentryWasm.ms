@wasm
export function lendWritable(cb: (xs: Span<int32>) => void): int32 {
	let v: Vec<int32> = [1, 2, 3];
	cb(v);
	return v[0] + v[1] + v[2];
}

@wasm
export function lendReadonly(cb: (xs: Readonly<Span<float64>>) => float64): float64 {
	let v: Vec<float64> = [1.5, 2];
	return cb(v);
}

@wasm
export function outer(cb: (n: int32) => int32): int32 {
	return cb(7);
}

@wasm
export function twice(n: int32): int32 {
	return n * 2;
}
