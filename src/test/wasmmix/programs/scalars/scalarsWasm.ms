@wasm
export function add32(a: int32, b: int32): int32 {
	return a + b;
}

@wasm
export function sub32(a: int32, b: int32): int32 {
	return a - b;
}

@wasm
export function add64(a: int64, b: int64): int64 {
	return a + b;
}

@wasm
export function widen32(a: float32): float64 {
	return a;
}

@wasm
export function mulHalf(a: float32, b: float32): float32 {
	return a * b;
}

@wasm
export function sum64f(a: float64, b: float64): float64 {
	return a + b;
}

@wasm
export function isEven(n: int32): boolean {
	return n % 2 == 0;
}

@wasm
export function wrapU8(a: uint8, b: uint8): uint8 {
	return a + b;
}
