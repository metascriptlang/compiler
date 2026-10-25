// Parity program — a struct imported from a C header whose every field translates exactly takes
// its size from MetaScript: `sizeof T` is a constant that fits a `size_t` field with no cast (the
// versioned-struct idiom), equals C's `sizeof`, and the struct is passed by value and embedded in
// a MetaScript struct with C's layout. A union's sizeof also takes an explicit `as uint64`.
// Axes: a module-level and a local versioned initializer, a struct nesting the complete one passed
// by value to C and through a MetaScript function, an embedding MetaScript struct, and a union.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @xfail(raiser): raiser has no C layout, so `sizeof` of a header struct is refused
// @stdout: 24 true 7 true | 64 true
// @stdout: 152 152 | 32 3 | 8 true
// @exit: 0

@include("./szImpl.h");

import {
	Corpus1141Versioned, Corpus1141Big, Corpus1141U,
	corpus1141VersionedSize, corpus1141BigSize, corpus1141USize, corpus1141Accept, corpus1141BigSum,
} from "./sz.h";

const shared: Corpus1141Versioned = { size: sizeof Corpus1141Versioned, a: 7, b: 1.5 };

struct Holder { inner: Corpus1141Versioned; n: int32 }

function viaMs(big: Corpus1141Big): int64 {
	return corpus1141BigSum(big);
}

let local: Corpus1141Versioned = { size: sizeof Corpus1141Versioned, a: 7, b: 2.5 };
const accepted = corpus1141Accept(local as Ptr<Corpus1141Versioned>);
console.log(`${shared.size} ${shared.size == corpus1141VersionedSize()} ${accepted} ${local.size == shared.size} | `
	+ `${sizeof Corpus1141Big} ${sizeof Corpus1141Big == corpus1141BigSize()}`);

const big: Corpus1141Big = { v: shared, w: 10, x: 20, y: 30, z: 60, tag: 1 };
const h: Holder = { inner: shared, n: 3 };
const uSize = sizeof Corpus1141U as uint64;
console.log(`${corpus1141BigSum(big)} ${viaMs(big)} | ${sizeof Holder} ${h.n} | ${uSize} ${uSize == corpus1141USize()}`);
