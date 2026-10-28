// Top-level functions passed to libc's qsort and bsearch through a header's function-pointer
// typedef reach C as their symbols; C calls them back.
// sort.h only redeclares the libc prototypes: a system header imports no names, and a header
// import is the declaration this program pins.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @skip-raiser: qsort and bsearch call back into compiled code, which Raiser's host bridge does not
// @stdout: 1,3,5,7,9|7|9,7,5,3,1
// @exit: 0

import { qsort, bsearch } from "./sort.h";

function ascending(a: Ptr<void> | null, b: Ptr<void> | null): int32 {
	if (a == null || b == null) return 0;
	return (a as Ptr<int32>)[0] - (b as Ptr<int32>)[0];
}

function descending(a: Ptr<void> | null, b: Ptr<void> | null): int32 {
	return ascending(b, a);
}

const xs: int32[] = [5, 3, 9, 1, 7];
qsort(xs[0], 5, 4, ascending);
const sorted = xs.join(",");
let key: int32 = 7;
const hit = bsearch(key, xs[0], 5, 4, ascending);
const found = hit != null ? (hit as Ptr<int32>)[0] : -1;
qsort(xs[0], 5, 4, descending);
console.log(`${sorted}|${found}|${xs.join(",")}`);
