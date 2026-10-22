// @xfail(raiser): raiser runtime error: Unknown host function: makeRes
// Parity program — an incomplete C struct or union that two headers name is one type, so a
// handle one header returns is the handle the other header takes.
// Axes: a struct and a union tag, named through a typedef in one header and bare in the other;
// a handle made through one header in one module and read through the other in another module,
// and one umbrella header that includes both. A typedef declared again in one translation unit
// is pinned in cimport/emit.ms, not here: it loops forever in compilers before the fix, and the
// gate builds this program with the base compiler.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 7 9|56
// @exit: 0

import { makeRes, makeCell } from "./a.h";
import { readBoth } from "./reader";
import { viaUmbrella } from "./umbrella";

console.log(`${readBoth(makeRes(7), makeCell(9))}|${viaUmbrella(5)}`);
