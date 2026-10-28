// Parity program — a C header struct's anonymous struct or union member is read and written
// through its field, and copied with the struct by value: the member is the extern struct named
// after its field, spelled in C as that field's type. A member with no name reads as the owner's.
// Axes: an anonymous struct, an anonymous union, one nested in another inside an array, an
// unnamed union, a copy taken before the writes, and the struct passed back to C by pointer.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @xfail(raiser): raiser runtime error: Unknown host function: corpusAnonMake
// @stdout: 3 4 5 6 8 7
// @stdout: 227 29
// @exit: 0

import { CorpusAnonOuter, corpusAnonMake, corpusAnonSum } from "./anon.h";

let o: CorpusAnonOuter = corpusAnonMake();
let copy = o;
o.inner.x = 30;
o.u.i = 50;
o.mid.leaf[1].a = 60;
o.tag = 80;
console.log(`${copy.inner.x} ${copy.inner.y} ${copy.u.i} ${copy.mid.leaf[1].a} ${copy.tag} ${copy.z}`);
console.log(`${corpusAnonSum(o as Ptr<CorpusAnonOuter>)} ${corpusAnonSum(copy as Ptr<CorpusAnonOuter>)}`);
