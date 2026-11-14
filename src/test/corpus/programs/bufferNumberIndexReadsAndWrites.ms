// @stdout: sum 84 | last 21 | 8
// @exit: 1
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
// note: a Buffer read and written through number indexes gives the same bytes on every backend, and an index past the end stops with the index error.
import { Buffer } from "std/core/buffer";

const b = Buffer.alloc(8);
for (let i = 0.0; i < 8; i += 1) b[i] = (i * 3) as uint8;
let sum = 0;
for (let i = 0.0; i < 8; i += 1) sum += b[i];
const at = 7.0;
console.log(`sum ${sum} | last ${b[at]} | ${b.length}`);
const far = 8.0;
console.log(`unreachable ${b[far]}`);
