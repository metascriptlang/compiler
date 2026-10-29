// @stdout: 42
// @stdout: -7
// @stdout: 9007199254740995
// @stdout: 0.10000000149011612
// @stdout: 0.75
// @stdout: 0.30000000000000004
// @stdout: true
// @stdout: false
// @stdout: 44
import { add32, sub32, add64, widen32, mulHalf, sum64f, isEven, wrapU8 } from "./scalarsWasm";

console.log(`${add32(40, 2)}`);
console.log(`${sub32(5, 12)}`);
console.log(`${add64(9007199254740993, 2)}`);
console.log(`${widen32(0.1)}`);
console.log(`${mulHalf(1.5, 0.5)}`);
console.log(`${sum64f(0.1, 0.2)}`);
console.log(`${isEven(10)}`);
console.log(`${isEven(7)}`);
console.log(`${wrapU8(200, 100)}`);
