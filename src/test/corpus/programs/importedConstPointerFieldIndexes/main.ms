// An element of an imported `const T*` struct field reads like one of a `T*` field: the field
// is the stored pointer, a `Ptr<T>`, and indexing it types the element (a `Borrow<T>` field
// left the element type unresolved and codegen stopped on it).
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @xfail(raiser): a C header import has no host bridge on the Raiser, card .inbox/compiler/2026-10-27-raiser-has-no-host-bridge-for-a-user-c-header-import
// @stdout: 7,8,9|-70000,80000,90000|80000,90000
// @exit: 0

import { fillBytes, fillInts, ByteView, IntView } from "./view.h";

extern function fillB(out v: ByteView): void from "fillBytes";
extern function fillI(out v: IntView): void from "fillInts";

interface Pair {
	a: int32;
	b: int32;
}

let bv: ByteView;
fillB(bv);
let bytes: Vec<uint8> = [0, 0, 0];
for (let i = 0; i < 3; i++) { bytes[i] = bv.ptr[i]; }

let iv: IntView;
fillI(iv);
let slots: int32[3] = [0, 0, 0];
for (let i = 0; i < 3; i++) { slots[i] = iv.ip[i]; }

const pair: Pair = { a: iv.ip[1], b: iv.ip[2] };
console.log(`${bytes[0]},${bytes[1]},${bytes[2]}|${slots[0]},${slots[1]},${slots[2]}|${pair.a},${pair.b}`);
