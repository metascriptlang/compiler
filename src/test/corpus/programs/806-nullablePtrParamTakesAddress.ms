// @stdout: 9|0|5,5|7
// @exit: 0

// A MetaScript function never receives a struct's address through a `Ptr<S> | null` parameter:
// that promotion is for extern C functions only (corpus 805, 807; fixedbugs bug209). Code that
// reads the caller's struct takes it by value, code that writes it takes `ref`, and the nullable
// pointer parameter takes a pointer or `null`.
// Axes: a read, null, a write through `ref`, a struct field of a local.

struct P { a: int32; }
struct Box { inner: P; tag: int32; }

function read(p: P): int32 { return p.a; }
function readOpt(p: Ptr<P> | null): int32 { return p == null ? 0 : p.a; }
function write(ref p: P): void { p.a = 5; }

const v: P = { a: 9 };
const before = read(v);
const none = readOpt(null);
let w: P = { a: 1 };
write(w);
const b: Box = { inner: { a: 7 }, tag: 1 };
console.log(`${before}|${none}|${w.a},${read(w)}|${read(b.inner)}`);
