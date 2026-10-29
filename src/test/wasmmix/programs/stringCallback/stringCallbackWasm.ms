@wasm();

export function probe(callback: (s: string) => int32): int32 {
	return callback("a\uD800b\0c");
}
