// @xfail(raiser): raiser runtime error: Unknown host function: corpus809MakeTag
// Parity program — an `extern struct` without a body is an opaque C struct: a pointer to it
// reaches C as a pointer to that struct under its C name, never as `void*`, so the C compiler
// sees the prototype's own type and `-Werror=incompatible-pointer-types` holds.
// Axes: a bare struct tag named by `from "struct T"` and a typedef'd struct named by itself;
// the pointer as return, param and through `ref` as a pointer to the pointer.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @stdout: 1,2|2,1|3
// @exit: 0

@include("./opaque.h");
@passC("-Werror=incompatible-pointer-types");

extern struct Tag from "struct Corpus809Tag";
extern struct Corpus809Named;

extern function corpus809MakeTag(v: int32): Ptr<Tag>;
extern function corpus809TagValue(t: Ptr<Tag>): int32;
extern function corpus809TagSwap(ref a: Ptr<Tag>, ref b: Ptr<Tag>): void;
extern function corpus809TagFree(t: Ptr<Tag>): void;
extern function corpus809MakeNamed(v: int32): Ptr<Corpus809Named>;
extern function corpus809NamedValue(n: Ptr<Corpus809Named>): int32;
extern function corpus809NamedFree(n: Ptr<Corpus809Named>): void;

let a: Ptr<Tag> = corpus809MakeTag(1);
let b: Ptr<Tag> = corpus809MakeTag(2);
const before = `${corpus809TagValue(a)},${corpus809TagValue(b)}`;
corpus809TagSwap(a, b);
const n = corpus809MakeNamed(3);
console.log(`${before}|${corpus809TagValue(a)},${corpus809TagValue(b)}|${corpus809NamedValue(n)}`);
corpus809TagFree(a);
corpus809TagFree(b);
corpus809NamedFree(n);
