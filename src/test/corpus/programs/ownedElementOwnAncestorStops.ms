// note: pushing an object into the Vec<Owned<T>> of its own descendant stops the program instead of closing an owned cycle.
// @exit: 1
// @stdout: Error: this N would own its own ancestor: the N storing it is the N itself or one of its descendants
// @skip-js: the single-owner check is built on C only so far (card unified-drc, backend parity step)
// @skip-raiser: the single-owner check is built on C only so far (card unified-drc, backend parity step)
class N {
	v: int32 = 0;
	kids: Vec<Owned<N>> = [];
	constructor(v: int32) { this.v = v; }
}
function main(): void {
	const a = new N(1); const b = new N(2);
	a.kids.push(b);
	b.kids.push(a);
	console.log("unreached");
}
main();
