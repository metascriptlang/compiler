@wasm
export function pick(callback: (x: int32) => int32 | null): int32 {
	return callback(1) ?? -1;
}
