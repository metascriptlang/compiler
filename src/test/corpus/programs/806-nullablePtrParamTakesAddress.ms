// @stdout: 9|0|5,5|7
// @exit: 0

// A struct value passed to a `Ptr<S> | null` parameter is passed by address, the way a Borrow<S>
// argument is: the callee reads the caller's value and a write through the pointer lands in the
// caller's local. Nothing checks that the callee does not keep the pointer past the call; this is
// the site an escape analysis would have to cover.
// Axes: a read, null, a write through the pointer, a struct field of a local.

struct P { a: int32; }
struct Box { inner: P; tag: int32; }

function read(p: Ptr<P> | null): int32 { return p == null ? 0 : p.a; }
function write(p: Ptr<P> | null): void { if (p != null) p.a = 5; }

const v: P = { a: 9 };
const before = read(v);
const none = read(null);
let w: P = { a: 1 };
write(w);
const b: Box = { inner: { a: 7 }, tag: 1 };
console.log(`${before}|${none}|${w.a},${read(w)}|${read(b.inner)}`);
