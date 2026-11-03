// @stdout: 2,3,4,5,6
// @stdout: 2,4,5,6,6
// @stdout: 3,5,5,6,6
// @stdout: 3,5,5,6,6
// @stdout: false,true,false,true
// @stdout: false,false,true,true
// @stdout: 2
// @stdout: 1,2,3
// @stdout: 1,4,6
// @stdout: 500500
// @stdout: 501499
// @stdout: 1,1001
import { bump, flip, scale, countOn, sumOf } from "./spanCopyPathsWasm";

let ints: Vec<int32> = [1, 2, 3, 4, 5];
bump(ints);
console.log(ints.join(","));
bump(ints[1..4]);
console.log(ints.join(","));
bump(ints[0..2]);
console.log(ints.join(","));
bump(ints[2..2]);
console.log(ints.join(","));

let flags: Vec<boolean> = [true, false, true, false];
flip(flags);
console.log(flags.join(","));
flip(flags[1..3]);
console.log(flags.join(","));
console.log(`${countOn(flags)}`);

let reals: Vec<float32> = [0.5, 1, 1.5];
scale(reals, 2);
console.log(reals.join(","));
scale(reals[1..3], 2);
console.log(reals.join(","));

let big: Vec<int32> = [];
for (let i = 0; i < 1000; i += 1) big.push(i);
bump(big);
console.log(`${sumOf(big)}`);
bump(big[1..1000]);
console.log(`${sumOf(big)}`);
console.log(`${big[0]},${big[999]}`);
