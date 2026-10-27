// Parity program — a C23 enum with a fixed underlying type (`enum [tag] : type { ... }`) imports
// from a header: the header parse returns and the constants read back, and `sizeof` of the
// enum is the C compiler's own, asserted against C. A fixed type of any other width than int is
// refused at import (`src/module/cimport/emit.ms` tests), because MetaScript stores an imported
// enum at int width.
// Axes: `: int`, `: unsigned int`, a tag with `: int32_t` by name, a forward declaration
// `enum Tag : int;` followed by its definition.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @xfail(raiser): raiser has no C layout, so `sizeof` of a header type is refused
// @stdout: 0 7 | 1 200 3 9
// @stdout: 4 true
// @exit: 0

@include("./enImpl.h");

import {
	CorpusEnumFixedInt, CorpusEnumFixedUnsigned, CorpusEnumFixedTag, CorpusEnumFixedFwd, corpusEnumFixedSize,
} from "./en.h";

console.log(`${CorpusEnumFixedInt.CORPUS_ENUMFIXED_X as int32} ${CorpusEnumFixedInt.CORPUS_ENUMFIXED_Y as int32} | `
	+ `${CorpusEnumFixedUnsigned.CORPUS_ENUMFIXED_LO as int32} ${CorpusEnumFixedUnsigned.CORPUS_ENUMFIXED_HI as int32} `
	+ `${CorpusEnumFixedTag.CORPUS_ENUMFIXED_T as int32} ${CorpusEnumFixedFwd.CORPUS_ENUMFIXED_F as int32}`);

const asInt: uint64 = sizeof CorpusEnumFixedInt;
console.log(`${asInt} ${asInt == corpusEnumFixedSize()}`);
