// @xfail(raiser): a C header import has no host bridge on the Raiser, card .inbox/compiler/2026-10-27-raiser-has-no-host-bridge-for-a-user-c-header-import
// A header imported from .ms names size_t through <stdlib.h>, <string.h> or <stdio.h>, which
// declare it in C, and through a runtime header that reaches it only that way.
// Axes: size_t as a parameter and result, behind a pointer, from an included header, and a
// runtime header include beside them.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 42|4|8
// @exit: 0

import { szTwice, szStore, szLength, size_t } from "./sz.h";

let cell: size_t = 0;
szStore(cell, 7);
console.log(`${szTwice(21)}|${szLength("abcd")}|${cell}`);
