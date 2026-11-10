// @stdout: whole 8 0 8
// @stdout: from 2 6 2 3
// @stdout: part 3 2 3 9
// @stdout: uint8 8 9
// @exit: 0

// A Buffer built over an ArrayBuffer views it as Node's Buffer does, with one, two or three
// constructor arguments, on every backend: the length the caller left out is the rest of the
// buffer, and a write through one view is read through the others.

import { Buffer } from "std/core/buffer";

const store = new ArrayBuffer(8);
const whole = new Buffer(store);
console.log(`whole ${whole.length} ${whole.byteOffset} ${whole.buffer.byteLength}`);
const from = new Buffer(store, 2);
from[1] = 3;
console.log(`from ${from.byteOffset} ${from.length} ${from.byteOffset} ${whole[3]}`);
const part = new Buffer(store, 2, 3);
whole[4] = 9;
console.log(`part ${part.length} ${part.byteOffset} ${part[1]} ${part[2]}`);
const u = new Uint8Array(store);
console.log(`uint8 ${u.length} ${u[4]}`);
