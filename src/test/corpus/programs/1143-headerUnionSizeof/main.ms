// Parity program — a C header union's layout is MetaScript's: every member at offset 0, the size
// the largest member rounded up to the strictest member alignment. `sizeof` of the union, and of a
// struct holding one, is a constant that fits a `size_t` or `uint64` slot with no cast, equals C's
// `sizeof`, and the build asserts it against C.
// Axes: a top-level union, a struct holding a union of a padded struct (the libghostty-vt
// GhosttyStyle shape) passed to C, a union of a padded struct, mixed alignment (char[5] + int64),
// rounding (char[9] + int32), a union nested in a union, and a struct holding all of them.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @xfail(raiser): raiser has no C layout, so `sizeof` of a header struct is refused
// @stdout: 8 true | 48 true 6
// @stdout: 24 true | 8 true | 12 true | 24 true | 88 true
// @exit: 0

@include("./unImpl.h");

import {
	Corpus1143Top, Corpus1143Style, Corpus1143PadUnion, Corpus1143Mixed, Corpus1143Round, Corpus1143Nest,
	Corpus1143Holder, corpus1143Size, corpus1143Fg,
} from "./un.h";

const top: Corpus1143Top = { size: sizeof Corpus1143Top };
let style: Corpus1143Style = { size: sizeof Corpus1143Style };
style.fg.value.rgb.r = 1;
style.fg.value.rgb.g = 2;
style.fg.value.rgb.b = 3;
console.log(`${top.size} ${top.size == corpus1143Size(0)} | `
	+ `${style.size} ${style.size == corpus1143Size(1)} ${corpus1143Fg(style as Ptr<Corpus1143Style>)}`);

const padded: uint64 = sizeof Corpus1143PadUnion;
const mixed: uint64 = sizeof Corpus1143Mixed;
const round: uint64 = sizeof Corpus1143Round;
const nest: uint64 = sizeof Corpus1143Nest;
const holder: Corpus1143Holder = { size: sizeof Corpus1143Holder, tail: 1 };
console.log(`${padded} ${padded == corpus1143Size(2)} | ${mixed} ${mixed == corpus1143Size(3)} | `
	+ `${round} ${round == corpus1143Size(4)} | ${nest} ${nest == corpus1143Size(5)} | `
	+ `${holder.size} ${holder.size == corpus1143Size(6)}`);
