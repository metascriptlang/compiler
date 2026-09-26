// @xfail(raiser): raiser runtime error: Unknown host function: corpus821Time
// Parity program — system headers included by a header imported with `import { … } from "./x.h"`
// resolve from the importer's builtin headers, under the #if branch of the build target.
// Axes: <time.h> in the imported header; <windows.h> or <unistd.h>, by the build target's
// branch, in a header it includes.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 1|2
// @exit: 0

import { corpus821Time, corpus821Branch } from "./sys.h";

console.log(`${corpus821Time()}|${corpus821Branch()}`);
