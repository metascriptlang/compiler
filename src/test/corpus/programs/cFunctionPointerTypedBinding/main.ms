// A binding typed by a header function-pointer typedef holds a module-level function as its
// C symbol: a module-level `let` and `const`, a local, and the value passed on to a header
// parameter. The pointer also crosses into a `const void*` parameter by `as Ptr<void>`, from
// the function, from a typed binding and through `as CorpusFn`, as the pointer's own value.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 7,7,7,7,1,2,3,4,
// @exit: 0

import { CorpusFn, corpusCallIt, corpusSetOpt } from "./sort.h";

let seen = "";
function hit(n: int32): void { seen = seen + n.toString() + ","; }

let top: CorpusFn = hit;
corpusCallIt(top);
const fixed: CorpusFn = hit;
corpusCallIt(fixed);
function local(): void {
	let l: CorpusFn = hit;
	corpusCallIt(l);
	const m: CorpusFn = hit;
	corpusCallIt(m);
}
local();
corpusSetOpt(1, hit as Ptr<void>);
corpusSetOpt(2, top as Ptr<void>);
corpusSetOpt(3, hit as CorpusFn as Ptr<void>);
corpusSetOpt(4, fixed as Ptr<void>);
console.log(seen);
