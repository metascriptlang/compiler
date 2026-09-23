// @xfail(raiser): raiser runtime error: Unknown host function: corpus801Mixed
// Parity program — `Ptr<T> | null` and `Ref<T> | null` are emitted as a bare C pointer, so the
// compile-time `sizeof` folds them to one pointer too; counting them as a tagged union made a
// struct holding one disagree with the C layout it is passed to.
// Axes: Ptr<void> | null, Ptr<T> | null, Ref<T> | null alone; after mixed-width fields; after a
// uint8 (alignment of the pointer slot).
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @stdout: 1|1|1|24,24|16,16
// @exit: 0

@include("./ffi.h");

struct N { a: uint32; }
struct Bare { d: Ptr<void>; }
struct PtrVoid { d: Ptr<void> | null; }
struct PtrT { d: Ptr<N> | null; }
struct RefT { d: Ref<N> | null; }
struct Mixed { a: uint32; b: int16; c: uint64; d: Ptr<void> | null; }
struct Lead { a: uint8; p: Ptr<void> | null; }

extern function corpus801Mixed(): number;
extern function corpus801Lead(): number;

const bare: number = sizeof Bare;
const ptrVoid: number = sizeof PtrVoid;
const ptrT: number = sizeof PtrT;
const refT: number = sizeof RefT;
const mixed: number = sizeof Mixed;
const lead: number = sizeof Lead;
const same = (n: number) => n == bare ? "1" : "0";
console.log(`${same(ptrVoid)}|${same(ptrT)}|${same(refT)}|${mixed},${corpus801Mixed()}|${lead},${corpus801Lead()}`);
