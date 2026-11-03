// @ledger-balanced: Counter
// @stdout: 5
// @stdout: 12
// @stdout: 20
// @stdout: 13
import { Handle } from "std/ffi";
import { open, bump } from "./handleBasicWasm";

const a = open(5);
console.log(`${bump(a, 0)}`);
console.log(`${bump(a, 7)}`);
const b = open(20);
console.log(`${bump(b, 0)}`);
a.release();
const c = open(13);
console.log(`${bump(c, 0)}`);
b.release();
c.release();
