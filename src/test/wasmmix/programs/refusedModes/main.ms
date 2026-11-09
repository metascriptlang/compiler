// @mixed-error: refusedModesWasm.ms:2:30
// @mixed-error: parameter 'xs' is 'ref Vec<int32>', and a Vec crosses the boundary only as a copy for the call
// @mixed-error: refusedModesWasm.ms:7:17
// @mixed-error: it takes the ref parameter 'n' and a callback, and the callback runs JS while wasm holds the copy of 'n'
// @mixed-error: refusedModesWasm.ms:13:29
// @mixed-error: parameter 1 of parameter 'visit' is 'ref int32', and a callback crossing the boundary cannot write a variable of its wasm caller
// @mixed-error: refusedModesWasm.ms:20:29
// @mixed-error: parameter 1 of parameter 'visit' is 'sink string', and a callback crossing the boundary takes its parameters as copies
// @stdout: 7,1,2
// @stdout: visit 4
// @stdout: 5
// @stdout: 11
// @stdout: handed
import { grow, countUp, lend, hand } from "./refusedModesWasm";

let xs: Vec<int32> = [7];
grow(xs);
grow(xs);
console.log(xs.join(","));
let n: int32 = 4;
countUp(n, (x: int32): void => {
	console.log(`visit ${x}`);
});
console.log(`${n}`);
console.log(`${lend((ref x: int32): void => {
	x = x + 10;
})}`);
hand((sink s: string): void => {
	console.log(s);
});
