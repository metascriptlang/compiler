// @xfail(raiser): Map needs an array field default and new Array(n) on the Raiser VM, card .inbox/compiler/2026-09-27-raiser-map-needs-array-defaults-and-new-array.md
// @stdout: values-ok push=1 inner=1 set=2 tags=1 fill=1 slice=1 at=1 concat=1 spread=1 elem=2 local=2 field=3 nested=2 param=9/1 forof=1
// note: a value struct stored into a new home is a copy of its own (push, Map.set, fill, slice, at, concat, spread), and an assignment into a location that already holds one writes into it, so every Ptr to that location sees the new value; a value parameter and a for-of binding rebind. Same output on every backend.

struct S { n: int32; }
struct H { s: S; }
struct In { v: int32; tags: Vec<int32>; }
struct Out { a: int32; inner: In; }

function keep(xs: S[], x: S): void { xs.push(x); }
function rebind(x: S): int32 { x = { n: 9 }; return x.n; }

let v: S = { n: 1 };
const vs: Vec<S> = [];
vs.push(v);
const rs: S[] = [];
keep(rs, v);
v.n = 2;

let o: Out = { a: 1, inner: { v: 2, tags: [1] } };
const m = new Map<string, Out>();
m.set("k", o);
o.inner.tags.push(5);
o.inner.v = 7;
const g = m.get("k")!;

const fv: S = { n: 1 };
const fs: S[] = [{ n: 0 }, { n: 0 }];
fs.fill(fv);
fs[0].n = 5;

const xs: S[] = [{ n: 1 }];
const sl = xs.slice(0, 1);
let at = xs.at(0)!;
const cc = xs.concat([]);
const sp: S[] = [...xs];
sl[0].n = 5;
at.n = 6;
cc[0].n = 7;
sp[0].n = 8;

let arr: S[1] = [{ n: 1 }];
const pe = arr[0] as Ptr<S>;
arr[0] = { n: 2 };
let lv: S = { n: 1 };
const pl = lv as Ptr<S>;
lv = { n: 2 };
let h: H = { s: { n: 1 } };
const pf = h.s as Ptr<S>;
h.s = { n: 3 };
let outs: Out[1] = [{ a: 1, inner: { v: 2, tags: [1] } }];
const po = outs[0] as Ptr<Out>;
outs[0] = { a: 3, inner: { v: 4, tags: [9, 9] } };

let pv: S = { n: 1 };
const r = rebind(pv);
const loop: S[] = [{ n: 1 }];
for (let x of loop) { x = { n: 9 }; }

console.log("values-ok push=" + vs[0].n.toString() + " inner=" + rs[0].n.toString()
	+ " set=" + g.inner.v.toString() + " tags=" + g.inner.tags.length.toString()
	+ " fill=" + fs[1].n.toString() + " slice=" + xs[0].n.toString() + " at=" + xs[0].n.toString()
	+ " concat=" + xs[0].n.toString() + " spread=" + xs[0].n.toString()
	+ " elem=" + pe.n.toString() + " local=" + pl.n.toString() + " field=" + pf.n.toString()
	+ " nested=" + po.inner.tags.length.toString() + " param=" + r.toString() + "/" + pv.n.toString()
	+ " forof=" + loop[0].n.toString());
