// note: plain locals move between Vec<Owned<T>> holders with push, pop, shift, an index store and a length cut; an element can sit under two holders at once, and one whose holder is destroyed, popped or cut away can be pushed again.
// @stdout: 3 2 0 1 2
class N {
	v: int32 = 0;
	kids: Vec<Owned<N>> = [];
	constructor(v: int32) { this.v = v; }
}
function keepKid(): N {
	const h = new N(1);
	const c = new N(2);
	h.kids.push(c);
	return c;
}
function main(): void {
	const root = new N(1); const a = new N(2); const b = new N(3);
	root.kids.push(a);
	root.kids.push(b);
	const x = root.kids.pop()!;
	const o = new N(4);
	o.kids.push(x);
	root.kids[0] = new N(5);
	o.kids.push(a);
	const y = o.kids.shift()!;
	root.kids.push(y);
	root.kids.length = 0;
	o.kids.push(y);
	let local: Vec<Owned<N>> = [];
	local.push(new N(6));
	const kept = keepKid();
	o.kids.push(kept);
	console.log(o.kids.length, o.kids[0].v, root.kids.length, local.length, kept.v);
}
main();
