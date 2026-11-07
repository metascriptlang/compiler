// note: an Owned field takes a plain local, a call result and a computed holder's store with no `move`; the local stays readable after the store, and an object its owner let go of can be stored again.
// @stdout: 5 5 1
// @stdout: 4 true 4 3
class N {
	v: int32 = 0;
	child: Owned<N> | null = null;
	parent: Unowned<N> | null = null;
	constructor(v: int32) { this.v = v; }
}
function make(v: int32): N { return new N(v); }
function main(): void {
	const root = new N(1); const a = new N(2);
	root.child = a;
	a.v = 5;
	a.parent = root;
	console.log(root.child!.v, a.v, a.parent!.v);
	root.child!.child = make(3);
	const holders: N[] = [root];
	holders[0].child = make(4);
	const b = root.child!;
	root.child = null;
	const o = new N(9);
	o.child = b;
	console.log(o.child!.v, root.child == null, b.v, a.child!.v);
}
main();
