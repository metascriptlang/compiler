// A routine handed to a `sink` slot of a header's function-pointer type stays a plain pointer:
// the generic `push` argument, a sink parameter of the typedef and a generic sink parameter
// instantiated at it.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 6 10 2|15|10
// @exit: 0

import { CorpusSinkUnary } from "./fns.h";

function twice(n: int32): int32 { return n * 2; }
function inc(n: int32): int32 { return n + 1; }
function thrice(n: int32): int32 { return n * 3; }

function callOwned(sink f: CorpusSinkUnary, n: int32): int32 { return f(n); }
function keep<T>(sink v: T): T { return v; }

const xs: CorpusSinkUnary[] = [inc];
xs.push(twice);
const kept: CorpusSinkUnary = keep<CorpusSinkUnary>(twice);
console.log(`${xs[0](5)} ${xs[1](5)} ${xs.length}|${callOwned(thrice, 5)}|${kept(5)}`);
