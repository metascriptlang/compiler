// @xfail(raiser): raiser runtime error: Unknown host function: corpus807MakeTag
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

extern struct Tag from "struct Corpus807Tag";
extern struct Corpus807Named;

extern function corpus807MakeTag(v: int32): Ptr<Tag>;
extern function corpus807TagValue(t: Ptr<Tag>): int32;
extern function corpus807TagSwap(ref a: Ptr<Tag>, ref b: Ptr<Tag>): void;
extern function corpus807TagFree(t: Ptr<Tag>): void;
extern function corpus807MakeNamed(v: int32): Ptr<Corpus807Named>;
extern function corpus807NamedValue(n: Ptr<Corpus807Named>): int32;
extern function corpus807NamedFree(n: Ptr<Corpus807Named>): void;

let a: Ptr<Tag> = corpus807MakeTag(1);
let b: Ptr<Tag> = corpus807MakeTag(2);
const before = `${corpus807TagValue(a)},${corpus807TagValue(b)}`;
corpus807TagSwap(a, b);
const n = corpus807MakeNamed(3);
console.log(`${before}|${corpus807TagValue(a)},${corpus807TagValue(b)}|${corpus807NamedValue(n)}`);
corpus807TagFree(a);
corpus807TagFree(b);
corpus807NamedFree(n);
