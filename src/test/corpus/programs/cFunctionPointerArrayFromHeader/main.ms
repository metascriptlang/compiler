// A header struct's array of function pointers holds module-level functions as C symbols:
// filled by element assignment, read and called as `t.fs[i](n)`, in an array of three, and
// nested one struct deep.
//
// @xfail(raiser): raiser has no host bridge for the header's C function 'corpusMakeTable', so the extern cannot run in the VM
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 10 6 3|6 7 8|11 20
// @exit: 0

import { corpusMakeTable, corpusMakeTriple, corpusMakeOuter } from "./sort.h";

function twice(n: int32): int32 { return n * 2; }
function inc(n: int32): int32 { return n + 1; }
function neg(n: int32): int32 { return 0 - n; }

let t = corpusMakeTable();
t.fs[0] = twice;
t.fs[1] = inc;
const a = t.fs[0](5);
const b = t.fs[1](5);
let triple = corpusMakeTriple();
triple.fs[0] = twice;
triple.fs[1] = inc;
triple.fs[2] = neg;
const c = triple.fs[2](-3);
let o = corpusMakeOuter();
o.inner.fs[0] = inc;
o.inner.fs[1] = twice;
console.log(`${a} ${b} ${c}|${triple.fs[0](3)} ${triple.fs[1](6)} ${triple.fs[0](4)}|${o.inner.fs[0](10)} ${o.inner.fs[1](10)}`);
