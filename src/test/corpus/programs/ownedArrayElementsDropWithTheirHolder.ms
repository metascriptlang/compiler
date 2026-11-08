// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: Owned<N>[] (a node under two parents), (Owned<N> | null)[] and Owned<N>[][] keep N acyclic, and dropping the root runs onDestroy once per node.
// @stdout: kids 3
// @stdout: made 13 gone 13
// @stdout: kids 3
// @stdout: made 16 gone 16
// @stdout: rows 2
// @stdout: made 20 gone 20
let made = 0;
let gone = 0;
class N {
	v: int32 = 0;
	kids: Owned<N>[] = [];
	maybe: (Owned<N> | null)[] = [];
	grid: Owned<N>[][] = [];
	constructor() { made += 1; }
	onDestroy(): void { gone += 1; }
}
function tree(): void {
	const r = new N();
	for (let i = 0; i < 3; i += 1) {
		const c = new N();
		r.kids.push(c);
		for (let j = 0; j < 3; j += 1) c.kids.push(new N());
	}
	const shared = r.kids[0];
	r.kids[1].kids.push(shared);
	console.log("kids", r.kids.length);
}
function nullable(): void {
	const r = new N();
	r.maybe.push(new N());
	r.maybe.push(null);
	r.maybe.push(new N());
	console.log("kids", r.maybe.length);
}
function nested(): void {
	const r = new N();
	r.grid.push([new N(), new N()]);
	r.grid.push([new N()]);
	console.log("rows", r.grid.length);
}
tree();
console.log("made", made, "gone", gone);
nullable();
console.log("made", made, "gone", gone);
nested();
console.log("made", made, "gone", gone);
