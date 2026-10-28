// A header struct's function-pointer field holds a module-level function as its C symbol:
// filled by a literal or an assignment, read back into libc's qsort, and called from .ms.
// sort.h only redeclares the libc prototype beside the structs: a system header imports no
// names, and a header import is the declaration this program pins.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @skip-raiser: qsort calls back into compiled code, which Raiser's host bridge does not
// @stdout: 1,3,5,7,9|3 42 4 8 9,7,5,3,1
// @exit: 0

import { qsort, CorpusSorter, CorpusOp } from "./sort.h";

function ascending(a: Ptr<void> | null, b: Ptr<void> | null): int32 {
	if (a == null || b == null) return 0;
	return (a as Ptr<int32>)[0] - (b as Ptr<int32>)[0];
}

function descending(a: Ptr<void> | null, b: Ptr<void> | null): int32 {
	return ascending(b, a);
}

function twice(n: int32): int32 { return n * 2; }
function inc(n: int32): int32 { return n + 1; }

let sorter: CorpusSorter = { compare: ascending, width: 4 };
const xs: int32[] = [5, 3, 9, 1, 7];
qsort(xs[0], 5, 4, sorter.compare);
const sorted = xs.join(",");
const doubler: CorpusOp = { op: twice, k: 3 };
let step: CorpusOp = { op: twice, k: 0 };
step.op = inc;
const kept = doubler.op;
sorter.compare = descending;
qsort(xs[0], 5, 4, sorter.compare);
console.log(`${sorted}|${doubler.k} ${doubler.op(21)} ${step.op(3)} ${kept(4)} ${xs.join(",")}`);
