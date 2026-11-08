// @maxrss: 40
// @skip-js: C-only by design: onDestroy counts the DRC's destroys; JS frees nothing
// @stdout: husks 1000000 destroyed 1000000 sum 499999500000
// note: a target destroyed while Unowned<T> edges still point at it keeps its memory only until the last edge goes, whether the edge is reassigned or its holder dies: a million such targets run in flat memory.
class N {
	id: int64 = 0;
	a: int64 = 0;
	b: int64 = 0;
	c: int64 = 0;
	d: int64 = 0;
	e: int64 = 0;
	f: int64 = 0;
	g: int64 = 0;
}
let destroyed = 0;
function onDestroy(this n: N): void { destroyed++; }
class H { at: Unowned<N> | null = null; }

let sum: int64 = 0;
function attach(h: H, i: int64): void {
	const n = new N();
	n.id = i;
	h.at = n;
	const seen = h.at;
	if (seen != null) sum += seen.id;
}

function round(i: int64): void {
	const h = new H();
	attach(h, i);
	if (i % 2 == 0) h.at = null;
}

const rounds: int64 = 1000000;
for (let i: int64 = 0; i < rounds; i++) round(i);
console.log("husks " + rounds.toString() + " destroyed " + destroyed.toString() + " sum " + sum.toString());
