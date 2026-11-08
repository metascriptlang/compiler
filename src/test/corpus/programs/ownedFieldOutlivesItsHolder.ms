// note: an object a local still holds outlives the holder of its Owned field; it can be stored again and can own others.
// @stdout: 2 4
function keepChild(): N {
	const h = new N(1);
	const c = new N(2);
	h.child = c;
	return c;
}
class N {
	v: int32 = 0;
	child: Owned<N> | null = null;
	constructor(v: int32) { this.v = v; }
}
function main(): void {
	const kept = keepChild();
	kept.child = new N(4);
	const o = new N(3);
	o.child = kept;
	console.log(o.child!.v, kept.child!.v);
}
main();
