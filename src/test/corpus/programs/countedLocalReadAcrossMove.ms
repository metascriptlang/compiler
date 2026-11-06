// note: a local holding a counted reference, read out of a place before the place is moved out, keeps the moved value it reads alive through its own count: across a refill of an element, as the moved element itself, and across a field moved out of a holder that dies.
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: still t5
// @stdout: ty gone t0
// @stdout: ty gone t5
// @stdout: refilled 105
// @stdout: key still 7 t7
// @stdout: ty gone t0
// @stdout: ty gone t7
// @stdout: refilled key 107
// @stdout: still t3
// @stdout: ty gone t0
// @stdout: ty gone t103
// @stdout: ty gone t3
// @stdout: holder 103
// @stdout: ty gone t107
// @stdout: ty gone t105
class Ty { name: string; constructor(n: string) { this.name = n; } }
function onDestroy(this t: Ty): void { console.log("ty gone", t.name); }
class N {
	v: int32;
	t: Ty;
	constructor(v: int32) { this.v = v; this.t = new Ty(`t${v}`); }
}
class H { k: Owned<N> = new N(3); }

function replaced(n: Owned<N>, t: Ty): Owned<N> {
	const w = new N(n.v + 100);
	n = new N(0);
	console.log("still", t.name);
	return w;
}
function replacedKey(n: Owned<N>, k: N): Owned<N> {
	const w = new N(n.v + 100);
	n = new N(0);
	console.log("key still", k.v, k.t.name);
	return w;
}
function refill(ref a: Owned<N>[]): void {
	const t = a[0].t;
	a[0] = replaced(move a[0], t);
}
function refillKey(ref a: Owned<N>[]): void {
	const k: N = a[0];
	a[0] = replacedKey(move a[0], k);
}
function dyingHolder(): int32 {
	const h = new H();
	const t = h.k.t;
	const g = replaced(move h.k, t);
	return g.v;
}

let xs: Owned<N>[] = [new N(5)];
refill(xs);
console.log("refilled", xs[0].v);
let ys: Owned<N>[] = [new N(7)];
refillKey(ys);
console.log("refilled key", ys[0].v);
console.log("holder", dyingHolder());
