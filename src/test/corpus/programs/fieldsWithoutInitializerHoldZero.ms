// @stdout: fields=0 0 false [] 0 0,0 0 0 0 true true 7 7 | locals=0 true true true | elements=30 | nullable=true true true
// note: a class field without an initializer holds its type's zero value on every backend: 0, false, "", a zeroed struct, an empty Vec, null for a class or a nullable; a declared local and a `new Array<T>(n)` element of a struct type are zeroed the same way, and a nullable local starts null (before, JS left the field undefined and started a nullable `int32` local at 0).
struct Pt { x: int32; y: int32; }
struct Ln { a: Pt; tag: string; delete: int64; }
class Inner { v: int32 = 5; }
class H {
	n: int32; f: float64; b: boolean; s: string; big: int64;
	p: Pt; l: Ln; v: Vec<int32>; inner: Inner; m: Inner | null; k: int32 = 7;
}
class Sub extends H {
	extra: Pt;
	constructor() { super(); this.extra.y = this.k; }
}
class Opt { q: int32 | null; r: Inner | null; s: Pt | null; }
const h = new Sub();
let lp: Pt;
let lq: int32 | null;
let lr: Inner | null;
let ls: Pt | null;
const arr = new Array<Pt>(2);
arr[0].x = 3;
const o = new Opt();
console.log(`fields=${h.n} ${h.f} ${h.b} [${h.s}] ${h.big} ${h.p.x},${h.p.y} ${h.l.a.y}${h.l.tag} ${h.l.delete} ${h.v.length} ${h.inner == null} ${h.m == null} ${h.k} ${h.extra.y} | locals=${lp.x} ${lq == null} ${lr == null} ${ls == null} | elements=${arr[0].x}${arr[1].x} | nullable=${o.q == null} ${o.r == null} ${o.s == null}`);
