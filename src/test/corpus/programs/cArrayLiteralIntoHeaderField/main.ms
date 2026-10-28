// An array literal fills a header struct's C-array field in an object literal, for an int
// array, an array of function pointers and a field one struct deep; assignment to the field
// from a literal already worked and stays alongside.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 1 2|10 6|7 8|3 4
// @exit: 0

import { CorpusLitInts, CorpusLitFns, CorpusLitOuter } from "./fields.h";

function twice(n: int32): int32 { return n * 2; }
function inc(n: int32): int32 { return n + 1; }

const v: CorpusLitInts = { xs: [1, 2] };
const f: CorpusLitFns = { fs: [twice, inc], k: 3 };
const o: CorpusLitOuter = { inner: { xs: [7, 8] }, k: 1 };
let w: CorpusLitInts = { xs: [0, 0] };
w.xs = [3, 4];
console.log(`${v.xs[0]} ${v.xs[1]}|${f.fs[0](5)} ${f.fs[1](5)}|${o.inner.xs[0]} ${o.inner.xs[1]}|${w.xs[0]} ${w.xs[1]}`);
