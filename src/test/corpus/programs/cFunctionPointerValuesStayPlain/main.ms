// A header's function-pointer type holds a plain routine wherever it is stored: an array of
// it is destroyed as plain words, and a module binding, a local, a parameter, a struct field
// and a C-array field hold and call the routine without a closure environment.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 10 6 14|10|6|14|10 6|10 3
// @exit: 0

import { CorpusPlainUnary, CorpusPlainOne, CorpusPlainPair } from "./fns.h";

function twice(n: int32): int32 { return n * 2; }
function inc(n: int32): int32 { return n + 1; }
function thriceLess(n: int32): int32 { return n * 3 - 1; }

const table: CorpusPlainUnary[] = [twice, inc, thriceLess];
let chosen: CorpusPlainUnary = inc;
chosen = twice;

function viaLocal(): int32 {
	const f: CorpusPlainUnary = inc;
	return f(5);
}

function viaParam(f: CorpusPlainUnary, n: int32): int32 {
	return f(n);
}

const one: CorpusPlainOne = { f: twice, k: 3 };
const pair: CorpusPlainPair = { fs: [twice, inc], k: 3 };
console.log(`${table[0](5)} ${table[1](5)} ${table[2](5)}|${chosen(5)}|${viaLocal()}|${viaParam(thriceLess, 5)}|${pair.fs[0](5)} ${pair.fs[1](5)}|${one.f(5)} ${one.k}`);
