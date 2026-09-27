// @stdout: box 1 2
// @exit: 0
// note: two modules each declare a class `Box`; a's lives in a module-level global and is still alive at exit, b's is dropped. The SAN ledger counts each TypeInfo on its own row, so a's row reads alloc=1 destroy=0 and b's alloc=1 destroy=1; when rows were keyed by the printed name the two merged into `Box alloc=2 destroy=1` and the lane went red on a program that frees everything it should.

import { fromA } from "./a";
import { fromB } from "./b";

console.log(`box ${fromA()} ${fromB()}`);
