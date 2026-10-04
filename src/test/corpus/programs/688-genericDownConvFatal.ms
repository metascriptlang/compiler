// @exit: 1
// @stdout: before 7
// @skip-js: node exits 1 with the same "invalid object conversion" line but wraps it in its own uncaught-error report, and parity compares merged stdout+stderr (sibling of 647)
// @xfail(danger): --danger drops the forced conversion check, so the wrong downcast reads the other instance's memory instead of stopping
// @xfail(raiser): the Raiser VM does not check object conversions

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}

function asNumber(u: unknown): number {
	return (u as Box<number>).v;
}

function main(): void {
	console.log(`before ${asNumber(new Box<number>(7))}`);
	console.log(`after ${asNumber(new Box<string>("s"))}`);
}
main();
