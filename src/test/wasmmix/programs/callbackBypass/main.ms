// @stdout: 41
// @stdout: -3
// @stdout: 13
// @stdout: 4294967297
// @stdout: ttt
// @stdout: 11
// @stdout: 1
// @stdout: 4294967295
import { addI32, seven, applyI32, applyWide, tick, probeBool, probeByte, probeU32 } from "./callbackBypassWasm";

console.log(`${applyI32(20, (x: int32): int32 => x * 2)}`);
console.log(`${applyI32(1, (x: int32): int32 => applyI32(x, (y: int32): int32 => y - 6))}`);
console.log(`${applyI32(5, (x: int32): int32 => addI32(x, seven()))}`);
console.log(`${applyWide((x: int64, y: float32): int64 => y > 0.25 ? x + 1 : x)}`);
const marks: string[] = [];
tick(3, (): void => { marks.push("t"); });
console.log(marks.join(""));
console.log(`${probeBool((b: boolean): int32 => b ? 10 : 1)}`);
console.log(`${probeByte((x: uint8): boolean => x == 200)}`);
console.log(`${probeU32((x: uint32): uint32 => x)}`);
