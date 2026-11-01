// @stdout: ctorCapture=7
// @stdout: plain=11
// @stdout: add=12
// @stdout: addAfter=22
// @stdout: bump1=11
// @stdout: bump2=12
// @stdout: nested=101
// @stdout: callback=25
// @stdout: second=12,22
// @stdout: derived=20,31
// An instance field initializer runs in the constructor, so `this` in it, alone or inside an
// arrow, is the instance under construction.

type Handler = (n: int32) => int32;

class Adder {
	base: int32 = 10;
	plain: int32 = this.base + 1;
	add = (x: int32): int32 => x + this.base;
}

class Derived extends Adder {
	extra: int32 = this.base * 2;
	twice = (x: int32): int32 => this.add(x) + this.extra;
}

class Counter {
	n: int32 = 10;
	bump = (): int32 => { this.n = this.n + 1; return this.n; };
}

class Maker {
	base: int32 = 1;
	maker = (): Handler => (n: int32): int32 => n + this.base;
}

class Scaled {
	r: int32 = 0;
	constructor(k: int32) {
		const f = (x: int32): int32 => x + k;
		this.r = f(2);
	}
}

function apply(h: Handler, n: int32): int32 {
	return h(n);
}

function main(): void {
	const a = new Adder();
	console.log("plain=" + a.plain.toString());
	console.log("add=" + a.add(2).toString());
	a.base = 20;
	console.log("addAfter=" + a.add(2).toString());
	const c = new Counter();
	console.log("bump1=" + c.bump().toString());
	console.log("bump2=" + c.bump().toString());
	const m = new Maker();
	const nested = m.maker();
	m.base = 100;
	console.log("nested=" + nested(1).toString());
	console.log("callback=" + apply(a.add, 5).toString());
	const b = new Adder();
	console.log("second=" + b.add(2).toString() + "," + a.add(2).toString());
	const d = new Derived();
	console.log("ctorCapture=" + new Scaled(5).r.toString());
	console.log("derived=" + d.extra.toString() + "," + d.twice(1).toString());
}
main();
