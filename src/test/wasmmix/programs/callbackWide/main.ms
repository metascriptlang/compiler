// @stdout: 40000000117
import { wide } from "./callbackWideWasm";

console.log(`${wide((a: int32, b: float64, c: boolean, d: int64, s: string, e: float32): int64 => {
	let r: int64 = d + (a as int64);
	if (c) r = r + 100;
	return r + (s.length as int64) + ((b * 2) as int64) + ((e * 4) as int64);
})}`);
