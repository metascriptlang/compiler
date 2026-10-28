// A header struct's function-pointer field and array element compare with null as a plain
// C pointer, with `===`, `!=` and `??`, while a function-typed local keeps the closure
// layout; an empty field and a filled field give opposite answers.
//
// @xfail(raiser): raiser has no host bridge for the header's C function 'corpusNullEmptyBox', so the extern cannot run in the VM
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: false true 8 4|true false 5|false true|false true
// @exit: 0

import { CorpusNullBox, CorpusNullTable, corpusNullEmptyBox } from "./fns.h";

function twice(x: int32): int32 { return x * 2; }
function inc(x: int32): int32 { return x + 1; }

const b: CorpusNullBox = { f: twice };
const e = corpusNullEmptyBox();
const t: CorpusNullTable = { fs: [twice, inc] };
const local: (x: int32) => int32 = twice;
const picked = b.f ?? inc;
const fallback = e.f ?? inc;
console.log(`${b.f === null} ${b.f != null} ${b.f(4)} ${picked(2)}|${e.f === null} ${e.f != null} ${fallback(4)}|${t.fs[0] === null} ${t.fs[1] != null}|${local === null} ${local !== null}`);
