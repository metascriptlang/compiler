// @stdout: 14
// @stdout: 1008
// @stdout: 264
// @stdout: 0.5
import { fill, push, sum } from "./floatViewWasm";

fill(8);
console.log(`${sum()}`);
let len = 0;
for (let i = 0; i < 1000; i = i + 1) { len = push(0.25); }
console.log(`${len}`);
console.log(`${sum()}`);
fill(2);
console.log(`${sum()}`);
