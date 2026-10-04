// @xfail(raiser): raiser error: Cannot resolve module './lib' (an extern C module)
// Parity program — an exported `extern function` with a Span parameter is called from another module
// with the span's data pointer and length, the C ABI it is declared with, as a call in its own module is.
// Axes: a module const sized array, a filled sized array, a Vec, an empty array, a slice; a Readonly
// span and a mutable one followed by a scalar.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @stdout: 6 26 30 0 13
// @exit: 0
import { sumOf, fillFrom } from "./lib";

const T: int64[3] = [1, 2, 3];
let buf: int64[4] = [0, 0, 0, 0];
const v: Vec<int64> = [10, 20];
fillFrom(buf, 5);
const empty: int64[] = [];
console.log(`${sumOf(T)} ${sumOf(buf)} ${sumOf(v)} ${sumOf(empty)} ${sumOf(buf[1..3])}`);
