@wasm
export function twice(x: int32): int32 {
	return x * 2;
}

@wasm
export function twice(x: uint8): uint8 {
	return x + x;
}

@wasm
export function twice(x: float64): float64 {
	return x * 2;
}

@wasm
export function twice(x: string): string {
	return x + x;
}

@wasm
export function total(a: int32, b: int32): int32 {
	return a + b;
}

@wasm
export function total(a: int32, b: int32, c: int32): int32 {
	return a + b + c;
}

@wasm
export function sum(xs: Vec<int32>): int32 {
	let s: int32 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function sum(xs: Vec<float64>): float64 {
	let s: float64 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function apply(v: int32, cb: (x: int32) => int32): int32 {
	return cb(v) + 1;
}

@wasm
export function apply(v: float64, cb: (x: float64) => float64): float64 {
	return cb(v) + 0.25;
}
