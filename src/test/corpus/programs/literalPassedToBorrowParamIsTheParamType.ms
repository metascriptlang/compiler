// @stdout: lit=5 nested=12 method=9 class=7 again=5
// note: an object literal passed straight to a Borrow<T> parameter is typed as T, so the callee reads a live T and not a stale slot.

struct Pair { a: int32; b: int32; }
struct Outer { head: Pair; tail: int32; }
class Cell { v: int32 = 0; }

function sum(p: Borrow<Pair>): int32 { return p.a + p.b; }
function total(o: Borrow<Outer>): int32 { return o.head.a + o.head.b + o.tail; }
function total(this p: Pair, extra: Borrow<Pair>): int32 { return p.a + extra.a + extra.b; }
function read(c: Borrow<Cell>): int32 { return c.v; }

const out: string[] = [];
out.push(`lit=${sum({ a: 4, b: 1 })}`);
out.push(`nested=${total({ head: { a: 4, b: 1 }, tail: 7 })}`);
const base: Pair = { a: 1, b: 0 };
out.push(`method=${base.total({ a: 5, b: 3 })}`);
out.push(`class=${read({ v: 7 })}`);
out.push(`again=${sum({ a: 2, b: 3 })}`);
console.log(out.join(" "));
