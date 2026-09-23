// @xfail(raiser): raiser runtime error: Unknown host function: corpus805New
// Parity program — a C constructor that returns a handle through `T*` binds as `out p: T`, and
// a const struct pointer imports as a nullable `Ptr<S>`, so `NULL` and a real config both pass.
// Axes: typedef'd handle and bare `struct S**`; the config param given null and a struct; each
// handle read and freed by a second call.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 0,7|0,42|1,11
// @exit: 0

import {
	corpus805New, corpus805Value, corpus805Free, corpus805NewRaw, corpus805RawValue, corpus805RawFree,
	Corpus805Handle, Corpus805Config,
} from "./handle.h";

let a: Corpus805Handle;
const ra = corpus805New(null, a);
const cfg: Corpus805Config = { base: 42 };
let b: Corpus805Handle;
const rb = corpus805New(cfg, b);
let raw: Ptr<void>;
const rr = corpus805NewRaw(raw);
console.log(`${ra},${corpus805Value(a)}|${rb},${corpus805Value(b)}|${rr},${corpus805RawValue(raw)}`);
corpus805Free(a);
corpus805Free(b);
corpus805RawFree(raw);
