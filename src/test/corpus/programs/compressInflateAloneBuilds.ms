// Parity program — std/compress/inflate alone builds: its miniz units need
// runtime/compress on the include path without std/compress/zip imported.
//
// @skip-js: std/compress has no JS surface
// @xfail(raiser): std/compress resolves only its zip submodule on Raiser
// @stdout: false
// @exit: 0

import { inflate } from "std/compress/inflate";

console.log(`${inflate("abc").ok}`);
