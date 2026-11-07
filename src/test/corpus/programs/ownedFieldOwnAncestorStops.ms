// note: storing an object in an Owned field of its own descendant stops the program instead of closing an owned cycle.
// @exit: 1
// @stdout: Error: this N would own its own ancestor: the N storing it is the N itself or one of its descendants
// @skip-js: the single-owner check is built on C only so far (card unified-drc, backend parity step)
// @skip-raiser: the single-owner check is built on C only so far (card unified-drc, backend parity step)
class N {
	v: int32 = 0;
	child: Owned<N> | null = null;
	constructor(v: int32) { this.v = v; }
}
function main(): void {
	const a = new N(1); const b = new N(2);
	a.child = b;
	b.child = a;
	console.log("unreached");
}
main();
