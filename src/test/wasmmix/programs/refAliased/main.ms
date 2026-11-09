// @columns: mixed
// @stdout: threw both: parameter 'a' and parameter 'b' reach the same variable, and wasm works on a separate copy of each, so a write through one would be lost to the other: pass separate variables
// @stdout: 1 2
// @stdout: threw poke: parameter 'n' and parameter 'xs' reach the same variable, and wasm works on a separate copy of each, so a write through one would be lost to the other: pass separate variables
// @stdout: 2 5,2,9
// @stdout: threw nest: parameter 'box' and parameter 'n' reach the same variable, and wasm works on a separate copy of each, so a write through one would be lost to the other: pass separate variables
// @stdout: 1 4
import { Box, both, poke, nest } from "./refAliasedWasm";

function attempt(run: () => void): string {
	try {
		run();
		return "returned";
	} catch (e) {
		return "threw " + e.message;
	}
}

let x: int32 = 0;
let y: int32 = 1;
console.log(attempt((): void => {
	both(x, x);
}));
both(x, y);
console.log(`${x} ${y}`);
let arr: Vec<int32> = [1, 2, 9];
console.log(attempt((): void => {
	poke(arr[0], arr);
}));
const first = poke(arr[0], arr[1..2]);
console.log(`${first} ${arr.join(",")}`);
let box: Box = { n: 0, label: "b" };
console.log(attempt((): void => {
	nest(box, box.n);
}));
let other: int32 = 3;
nest(box, other);
console.log(`${box.n} ${other}`);
