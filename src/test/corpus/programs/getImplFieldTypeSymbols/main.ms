// @stdout: S AS GSS S E 0 | S E 0 | T USn C GC0S GSGSS I A0 | a.b.v a.c r.v
// @exit: 0
// note: getImpl of a type hands a macro its field types as nodes that carry their symbols, as the reference's typed declaration does: getImpl of a field type reads that type's declaration (struct, enum, class, interface, alias, a type of another module, a generic and its arguments, an array element, a nullable), a builtin gives null, and a macro walks nested types without looking a name up. The field types used to arrive only as text.

import { fieldDecls, leafPaths } from "./describe";
import { Remote } from "./shapes";

enum Mode { On, Off }
struct Inner { v: int32; }
struct Pair<T> { a: T; }
struct Outer { inner: Inner; xs: Inner[3]; p: Pair<Inner>; r: Remote; m: Mode; n: uint64; }
class Holder { inner: Inner = { v: 1 }; mode: Mode = Mode.On; n: uint64 = 0; }
class Box { n: int32 = 0; }
type Alias = Inner;
interface Shape { w: int32; }
struct Wide { al: Alias; maybe: Inner | null; box: Box; map: Map<string, Inner>; nested: Pair<Pair<Remote>>; sh: Shape; words: string[]; }
struct Mid { b: Inner; c: uint8; }
struct Top { a: Mid; r: Remote; }

console.log(`${fieldDecls(Outer)} | ${fieldDecls(Holder)} | ${fieldDecls(Wide)} | ${leafPaths(Top)}`);
