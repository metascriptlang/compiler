// @xfail(raiser): a C header import has no host bridge on the Raiser, card .inbox/compiler/2026-10-27-raiser-has-no-host-bridge-for-a-user-c-header-import
// libc fills bytes behind a pointer; `p[a..b]` views them as a Span without a copy.
// Axes: a size_t, an int32 and an inclusive end; a computed end; a write through the view that
// C reads back; a read-only pointer giving a Readonly<Span>; a slice passed to a Span parameter.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 6 hhXhh 5|hX|Xhh|504
// @exit: 0

import { size_t } from "./libc.h";
@include("./libc.h");

extern function malloc(size: size_t): Ptr<void>;
extern function free(p: Ptr<void>): void;
extern function memset(p: Ptr<void>, c: int32, n: size_t): Ptr<void>;
extern function strlen(s: Ptr<char>): size_t;

function sum(view: Readonly<Span<uint8>>): int32 {
	let total = 0;
	for (const b of view) total += b as int32;
	return total;
}

const n: size_t = 6;
const raw = malloc(n);
memset(raw, 104, n);
const bytes = raw as Ptr<uint8>;
const view: Span<uint8> = bytes[0..n];
view[5] = 0;
view[2] = 88;
const cut: int32 = 2;
const readOnly: Readonly<Ptr<uint8>> = bytes;
const pair: Readonly<Span<uint8>> = readOnly[1...cut];
console.log(`${view.length} ${view[0..5].asString()} ${strlen(raw as Ptr<char>)}|${pair.asString()}|${bytes[cut..cut + 3].asString()}|${sum(bytes[0..n - 1])}`);
free(raw);
