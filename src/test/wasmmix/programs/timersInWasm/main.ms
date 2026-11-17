// @stdout: 2
// @stdout: main end
// @stdout: then 1
// @stdout: soon 1
// @stdout: tick 1
// @stdout: tick 2
// @stdout: tick 3
// @stdout: timer 1
import { schedule } from "./timersInWasmCalc";

console.log(`${schedule(1)}`);
console.log("main end");
