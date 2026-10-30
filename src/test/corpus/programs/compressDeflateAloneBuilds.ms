// Parity program — std/compress/deflate alone builds: its miniz units need
// runtime/compress on the include path without std/compress/zip imported.
//
// @skip-js: std/compress has no JS surface
// @xfail(raiser): std/compress resolves only its zip submodule on Raiser
// @stdout: true 3
// @exit: 0

import { deflate } from "std/compress/deflate";

const r = deflate("abc");
console.log(`${r.ok} ${r.ok ? 3 : 0}`);
