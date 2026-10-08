// @exit: 1
// @stdout: before 7
// @xfail(danger): --danger drops the forced conversion check, so the wrong downcast reads the other instance's memory instead of stopping
// @skip-js: JS names the failed generic instance by its emitted class (`Box_164w9ka__string is not Box<number>`) where C writes `Box<string>`
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output

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
