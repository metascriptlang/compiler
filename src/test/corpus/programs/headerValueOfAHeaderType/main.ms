// @xfail(raiser): raiser runtime error: Unknown host function: valOf
// Parity program — a C variable of a header's type holds that type and does not name it, so the
// type keeps its own C name wherever the header is imported.
// Axes: a const of an anonymous typedef struct the program never reads, and a variable of a
// tagged struct it does read.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 2.5 8
// @exit: 0

import { valOf, spanOf, Val, wholeRange } from "./val.h";

const v: Val = { value: 2.5, unit: 1 };
console.log(`${valOf(v)} ${spanOf(wholeRange)}`);
