// @stdout: 4
// @stdout: 2
// @stdout: 33
import { depth, pair } from "./callbackDeepWasm";

console.log(`${depth(0, (n: int32): int32 => depth(n, (m: int32): int32 => depth(m, (k: int32): int32 => k + 1)))}`);
console.log(`${depth(1, (n: int32): int32 => n)}`);
console.log(`${pair(10, (x: int32): int32 => x + 1, (x: int32): int32 => x * 2)}`);
