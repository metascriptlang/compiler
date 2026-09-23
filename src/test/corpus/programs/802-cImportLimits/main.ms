// @xfail(raiser): raiser runtime error: Unknown host function: corpus802IntMax
// Parity program — a header imported with `import { … } from "./x.h"` that includes <limits.h>
// resolves it from the importer's builtin headers, the way it resolves <stdint.h>.
// Axes: <limits.h> in the imported header, again in a header it includes, and INT_MAX as the
// value of an enum member the importer evaluates.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 2147483647|2147483647|ok
// @exit: 0

import { corpus802IntMax, corpus802Sentinel, corpus802LongIsWide } from "./lim.h";

const wide = corpus802LongIsWide();
console.log(`${corpus802IntMax()}|${corpus802Sentinel()}|${wide == 0 || wide == 1 ? "ok" : "bad"}`);
