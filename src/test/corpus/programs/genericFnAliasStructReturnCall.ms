// @stdout: 7 x|8 ab 3|9 y|8
// note: a call through a closure typed by a generic function-type alias that returns a struct passes the result slot as an inline function type does, with one or two type parameters, an alias nested in another generic alias, and a scalar return as control.

struct Reply { status: int32; body: string; }
type Answer<F> = (failure: F) => Reply;
type Both<A, B> = (a: A, b: B) => Reply;
type Outer<F> = Answer<F>;
type Scalar<F> = (failure: F) => int32;

function answer<F>(failure: F, guest: Answer<F>): Reply { return guest(failure); }
function both<A, B>(a: A, b: B, guest: Both<A, B>): Reply { return guest(a, b); }
function nested<F>(failure: F, guest: Outer<F>): Reply { return guest(failure); }
function scalar<F>(failure: F, guest: Scalar<F>): int32 { return guest(failure); }

const r = answer(7, (n: int32): Reply => ({ status: n, body: "x" }));
const s = both(8, "ab", (n: int32, t: string): Reply => ({ status: n, body: t + t.length.toString().slice(0, 0) + "" }));
const t = nested(9, (n: int32): Reply => ({ status: n, body: "y" }));
console.log(`${r.status} ${r.body}|${s.status} ${s.body} ${s.body.length + 1}|${t.status} ${t.body}|${scalar(7, (n: int32): int32 => n + 1)}`);
