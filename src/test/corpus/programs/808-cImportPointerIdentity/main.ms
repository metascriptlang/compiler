// @xfail(raiser): raiser runtime error: Unknown host function: corpus808New
// Parity program — a C header's pointer to an incomplete struct or union imports as `Ptr<Tag>`
// over an opaque `extern struct` carrying the C spelling, so every local and out-param reaches C
// with the prototype's own pointer type and `-Werror=incompatible-pointer-types` holds.
// Axes: a pointer typedef `H` written through `H*`, a bare `struct S**`, a typedef named after
// its own tag written through `T**`, and a union pointer returned and passed back.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 0,1|0,2|0,3|4
// @exit: 0

@include("./ptrImpl.h");
@passC("-Werror=incompatible-pointer-types");

import {
	corpus808New, corpus808Value, corpus808Free,
	corpus808NewRaw, corpus808RawValue, corpus808RawFree,
	corpus808NewNamed, corpus808NamedValue, corpus808NamedFree,
	corpus808MakeCell, corpus808CellValue, corpus808CellFree,
	Corpus808Handle, Corpus808Raw, Corpus808Named,
} from "./ptr.h";

let h: Corpus808Handle;
const rh = corpus808New(h);
let raw: Ptr<Corpus808Raw>;
const rr = corpus808NewRaw(raw);
let named: Ptr<Corpus808Named>;
const rn = corpus808NewNamed(named);
const cell = corpus808MakeCell(4);
console.log(`${rh},${corpus808Value(h)}|${rr},${corpus808RawValue(raw)}|${rn},${corpus808NamedValue(named)}|${corpus808CellValue(cell)}`);
corpus808Free(h);
corpus808RawFree(raw);
corpus808NamedFree(named);
corpus808CellFree(cell);
