// @stdout: name:a name:b|kept|name:c name:d
// @xfail(raiser): raiser error: 'corpus1272Name' cannot run on the Raiser: no host bridge for 'corpus1272Name' — a C header import has no host bridge on the Raiser
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// A `const char *` a C function returns imports as cstring, a pointer the C side keeps. It becomes
// a string only where `as string` copies it, so a later call that rewrites the buffer, or a free,
// cannot change the string the author holds. Axes: a shared static buffer rewritten per call
// (const and function return), a heap buffer freed after the copy (read under ASan).
import { corpus1272Name, corpus1272Make, corpus1272Free } from "./held.h";

const a = corpus1272Name("a") as string;
const b = corpus1272Name("b") as string;
const heap = corpus1272Make("kept");
const kept = heap as string;
corpus1272Free(heap);
function named(s: string): string { return corpus1272Name(s) as string; }
const c = named("c");
const d = named("d");
console.log(`${a} ${b}|${kept}|${c} ${d}`);
