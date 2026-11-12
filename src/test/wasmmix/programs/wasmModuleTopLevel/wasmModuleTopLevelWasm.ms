export const seven: int32 = thrice(2) + 1;

@wasm
export function twice(x: int32): int32 {
	return x * 2;
}

@wasm
export function thrice(x: int32): int32 {
	return x * 3;
}
