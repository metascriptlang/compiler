// @xfail(raiser): raiser runtime error: Unknown host function: twice
// Parity program — the companion `.c` of an imported C header is built whenever the module
// that imports the header is, even when no MetaScript code reaches the header's functions.
// Axes: a function of the header called through an `extern function` of another module, and one
// called only from C (`caller.c`).
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 42 63
// @exit: 0

import "./sub/wrap";
@include("./sub/lib.h");
@include("./caller.h");
@compile("./caller.c");
extern function twice(x: int32): int32;
extern function viaC(x: int32): int32;

console.log(`${twice(21)} ${viaC(21)}`);
