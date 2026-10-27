// @stdout: a a a a a 3 a 5 Z
// @stdout: a a a a 3 3 b
// note: a field of a literal-union type that a literal leaves out takes the union's first member on every backend, in a struct, one struct deeper, an array element, a class literal and a number union, a sized-array field, and the slots of new Array<T>(n).
type F = "a" | "b";
type N = 3 | 4;
type Mixed = "Z" | 1;
struct S { f: F; n: int32; s: string; }
struct T { s: S; k: N; }
class C { f: F; n: int32 = 0; }
function make(): S { return { n: 1 }; }
const x: S = make();
const y: S = { n: 2 };
const t: T = {};
const arr: S[] = [{ n: 5 }];
const c: C = { n: 7 };
const m: { m: Mixed; n: int32 } = { n: 1 };
console.log(`${x.f} ${y.f} ${t.s.f} ${arr[0].f} ${c.f} ${t.k} ${t.s.f} ${arr[0].n} ${m.m}`);
struct H { f: F; a: F[3]; t: T[2]; }
const h: H = { f: "b" };
const grown = new Array<S>(2);
const letters = new Array<F>(2);
const ts = new Array<T>(1);
console.log(`${grown[1].f} ${letters[1]} ${h.a[2]} ${h.t[1].s.f} ${ts[0].k} ${h.t[0].k} ${h.f}`);
