// A header function-pointer field that returns a C pointer takes a .ms function that may
// return null, as its pointer parameters already do: C's NULL is the failure contract of an
// allocator callback. Read back, the field's result is nullable. A plain header function's
// `void*` return compares to null the same way.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 1 0 false true
// @exit: 0

import { CorpusVt, size_t, corpusTryAlloc, corpusSome, corpusNone } from "./sort.h";

function refuse(ctx: Ptr<void> | null, len: size_t): Ptr<void> | null {
	return null;
}

function grant(ctx: Ptr<void> | null, len: size_t): Ptr<void> | null {
	return corpusSome();
}

let v: CorpusVt = { alloc: refuse };
const refused = corpusTryAlloc(v as Ptr<CorpusVt>);
v.alloc = grant;
const granted = corpusTryAlloc(v as Ptr<CorpusVt>);
const got = v.alloc(null, 4);
console.log(`${refused} ${granted} ${got == null} ${corpusNone() == null}`);
