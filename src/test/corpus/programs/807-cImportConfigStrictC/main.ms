// @xfail(raiser): raiser runtime error: Unknown host function: corpus807Sum
// Parity program — a struct value passed to an imported `const S*` / `S*` parameter reaches C as
// exactly `S*`, so it builds with incompatible pointer types as an error (GCC 14's default).
// Axes: anonymous and tagged typedef struct, const and mutable pointee, null, a write the caller sees.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 7|-1|3|107
// @exit: 0

@passC("-Werror=incompatible-pointer-types");

import { corpus807Sum, corpus807Tag, corpus807Bump, Corpus807Config, Corpus807Tagged } from "./cfg.h";

const cfg: Corpus807Config = { base: 5, step: 2 };
const tagged: Corpus807Tagged = { k: 3 };
let mut: Corpus807Config = { base: 7, step: 0 };
corpus807Bump(mut);
console.log(`${corpus807Sum(cfg)}|${corpus807Sum(null)}|${corpus807Tag(tagged)}|${mut.base}`);
