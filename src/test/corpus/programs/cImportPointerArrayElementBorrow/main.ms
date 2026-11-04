// @xfail(raiser): raiser error: 'corpusPaMake' cannot run on the Raiser: no host bridge for 'corpusPaMake'
// Parity program — an element of a `Ptr<T>[N]` or `cstring[N]` array passed to a C `const T *`
// parameter goes as the element's address, so C reads the array from that element on; a class or
// array Borrow staying the reference itself is pinned by 1231-borrowReturnOfReferenceParam.
// Axes: an opaque handle and a C string element; element 0 and element 1; a module array and a
// function local. The header makes an incompatible pointer an error, so a value passed in place
// of the address fails the build.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: handles=6/5/5 names=6/5/5
// @exit: 0

import { corpusPaMake, corpusPaSum, corpusPaLen, CorpusPaImpl } from "./elems.h";

const NONE = null as unknown as Ptr<CorpusPaImpl>;
const hs: Ptr<CorpusPaImpl>[4] = [corpusPaMake(1), corpusPaMake(2), corpusPaMake(3), NONE];
const ns: cstring[3] = ["a", "bc", "def"];

function local(): string {
	const lh: Ptr<CorpusPaImpl>[3] = [corpusPaMake(1), corpusPaMake(2), corpusPaMake(3)];
	const ln: cstring[3] = ["a", "bc", "def"];
	return `${corpusPaSum(lh[1], 2)}/${corpusPaLen(ln[1], 2)}`;
}

const parts = local().split("/");
console.log(`handles=${corpusPaSum(hs[0], 4)}/${corpusPaSum(hs[1], 3)}/${parts[0]} names=${corpusPaLen(ns[0], 3)}/${corpusPaLen(ns[1], 2)}/${parts[1]}`);
