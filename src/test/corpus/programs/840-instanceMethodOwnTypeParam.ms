// @stdout: 1 y 1 x 5 3 s 7 1
// note: an instance method with its own type parameter is instantiated per call like a free generic function, with the receiver as parameter 0.

class Holder {
	n: int32 = 5;
	firstOf<T>(a: T, b: T): T { return a; }
	secondOf<T>(a: T, b: T): T { return b; }
	count<T>(a: T): int32 { return 3; }
	own(): int32 { return this.firstOf(this.n, 2); }
	chain<T>(a: T, b: T): T { return this.secondOf(b, a); }
}

class Box<U> {
	u: U;
	constructor(u: U) { this.u = u; }
	pick<T>(a: T, b: T): T { return a; }
	keep<T>(a: T): U { return this.u; }
}

const h = new Holder();
const b = new Box<string>("s");
const parts: string[] = [
	String(h.firstOf(1, 2)),
	h.secondOf("x", "y"),
	String(h.firstOf<int32>(1, 2)),
	h.firstOf("x", "y"),
	String(h.own()),
	String(h.count("q")),
	b.keep(1),
	String(b.pick(7, 8)),
	String(h.chain(1, 2)),
];
console.log(parts.join(" "));
