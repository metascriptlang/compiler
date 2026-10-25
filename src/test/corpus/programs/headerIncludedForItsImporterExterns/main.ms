// @xfail(raiser): raiser runtime error: Unknown host function: sumBytes
// Parity program — a module that imports a C header includes it in its C, so a C declaration the
// module writes itself compiles even when the program reaches no name imported from the header.
// Axes: an `extern function` with a `Span` parameter the header importer cannot map, and an
// `extern const` read.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 42 7
// @exit: 0

import { viaSum, limit } from "./sub/wrap";

const data: uint8[] = [40, 2];
console.log(`${viaSum(data)} ${limit()}`);
