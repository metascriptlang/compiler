// @stdout: a pq w | 7b 2rs 4x
// @xfail(raiser): output differs from c: the Box of a.ms reads as nil (the Raiser VM confuses the two Box classes)
import { fromA } from "./a";
import { fromB } from "./b";

console.log(`${fromA()} | ${fromB()}`);
