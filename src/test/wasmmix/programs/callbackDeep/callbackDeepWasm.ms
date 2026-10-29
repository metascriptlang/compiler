@wasm();

export function depth(value: int32, callback: (value: int32) => int32): int32 {
	return callback(value) + 1;
}

export function pair(value: int32, first: (value: int32) => int32, second: (value: int32) => int32): int32 {
	return first(value) + second(value) + 2;
}
