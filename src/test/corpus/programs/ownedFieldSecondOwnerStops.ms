// note: storing an object in a second Owned field while its first owner still holds it stops the program and names the type.
// @exit: 1
// @stdout: Error: this N already has an owner; an Owned<N> slot takes an object no other owned slot holds (remove it from its owner first)
// @skip-js: the single-owner check is built on C only so far (card unified-drc, backend parity step)
// @skip-raiser: the single-owner check is built on C only so far (card unified-drc, backend parity step)
class N {
	v: int32 = 0;
	child: Owned<N> | null = null;
	constructor(v: int32) { this.v = v; }
}
function main(): void {
	const o1 = new N(1); const o2 = new N(2); const a = new N(3);
	o1.child = a;
	o2.child = a;
	console.log("unreached");
}
main();
