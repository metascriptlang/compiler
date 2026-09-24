// @xfail(raiser): raiser runtime error: Unknown host function: corpus803Ok
// Parity program — a typedef'd C enum with negative members reaches MetaScript as an
// `extern enum` whose initializers are negated literals, and keeps their values.
// Axes: the enum as a return type (zero and negative member), as a parameter type, and a
// negative member read by name.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 0|-2|-10|-20
// @exit: 0

import { corpus803Ok, corpus803Fail, corpus803Take, Corpus803Result } from "./res.h";

console.log(`${corpus803Ok() as int32}|${corpus803Fail() as int32}|${corpus803Take(Corpus803Result.CORPUS803_OOM)}|${corpus803Take(corpus803Fail())}`);
