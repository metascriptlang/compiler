@wasm
export function addI32(a: int32, b: int32): int32 {
	return a + b;
}

@wasm
export function seven(): int32 {
	return 7;
}

@wasm
export function applyI32(value: int32, callback: (x: int32) => int32): int32 {
	return callback(value) + 1;
}

@wasm
export function applyWide(callback: (x: int64, y: float32) => int64): int64 {
	return callback(4294967296, 0.5);
}

@wasm
export function tick(n: int32, callback: () => void): void {
	for (let i = 0; i < n; i += 1) callback();
}

@wasm
export function probeBool(callback: (b: boolean) => int32): int32 {
	return callback(true) + callback(false);
}

@wasm
export function probeByte(callback: (x: uint8) => boolean): int32 {
	return callback(200) ? 1 : 0;
}

@wasm
export function probeU32(callback: (x: uint32) => uint32): uint32 {
	return callback(4294967295);
}

@wasm
export function probeU64(callback: (x: uint64) => uint64): uint64 {
	return callback(18446744073709551615);
}
