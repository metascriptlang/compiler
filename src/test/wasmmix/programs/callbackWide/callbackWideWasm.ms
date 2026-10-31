@wasm
export function wide(cb: (a: int32, b: float64, c: boolean, d: int64, s: string, e: float32) => int64): int64 {
	return cb(7, 2.5, true, 40000000000, "ab", 0.5) + 1;
}
