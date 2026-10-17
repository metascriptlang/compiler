// Parity program — a class, an enum and a generic function read through a namespace
// import name the module's declarations: a static method, a construction, an enum
// member and two generic instances, beside a variable read the same way.
//
// @stdout: lib body
// @stdout: start
// @stdout: 8 5 green 2 1 3

import * as m from "./lib";

console.log("start");
const words = m.pair("ab");
const nums = m.pair(1);
console.log(`${m.K.twice(4)} ${new m.K().plus(1)} ${m.label(m.Color.Green)} ${words.length} ${nums[1]} ${m.counter}`);
