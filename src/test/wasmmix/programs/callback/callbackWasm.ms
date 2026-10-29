@wasm();

export function evaluate(value: int32, callback: (value: int32) => int32): int32 {
	return callback(value) + 1;
}
