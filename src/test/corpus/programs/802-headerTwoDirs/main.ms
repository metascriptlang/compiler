// @xfail(raiser): raiser runtime error: Unknown host function: corpus802Twice
// Parity program — a C header imported from modules in different directories names one file,
// so its companion `.c` compiles and links once; the second path reaches it through `..`.
// Axes: importers one directory apart (`lib/` and `app/`), two levels apart (`a/b/` and `c/d/`).
//
// @skip-js: a `.h` import binds a C symbol; the JS backend has no C linkage
// @stdout: 4,6|6,9
// @exit: 0

import { twiceBoth } from "./app/direct";
import { thriceBoth } from "./c/d/direct";

console.log(`${twiceBoth(2 as int32)}|${thriceBoth(2 as int32)}`);
