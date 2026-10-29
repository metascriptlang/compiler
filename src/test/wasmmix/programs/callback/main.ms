// @stdout: 41
// @stdout: -3
import { evaluate } from "./callbackWasm";

console.log(`${evaluate(20, (x: int32): int32 => x * 2)}`);
console.log(`${evaluate(1, (x: int32): int32 => evaluate(x, (y: int32): int32 => y - 6))}`);
