// @skip-js: JS runs no destructors, so the hook output exists on C only
// note: two instances of one generic class own their own onDestroy: each instance's hook runs for its own type argument
class Cell<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	onDestroy(): void { console.log("destroy cell " + (typeof this.v == "number" ? "number" : "string")); }
}

{
	const n = new Cell<number>(1);
	const s = new Cell<string>("x");
	console.log(n.v, s.v);
}
console.log("end");
