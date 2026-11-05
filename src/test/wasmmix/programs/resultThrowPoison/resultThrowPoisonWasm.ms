@wasm
export function numbers(): Vec<int32> {
	return [1, 2, 3];
}

@wasm
export function text(): string {
	return "0123456789012345678901234567890123456789012345678901234567890123";
}

@wasm
export function ping(): int32 {
	return 7;
}
