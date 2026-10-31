// @stdout: 5
// @stdout: 11 21 base+mid+top
// @stdout: A.m via grand
// @stdout: 7 got
// note: super.m() runs the parent's m on this, never the override that is running: from an override returning nothing or a value, three levels deep, an inherited method from the grandparent, and a generic parent instance.
class A {
	n: number = 0;
	start(k: number): void { this.n = k; }
}
class B extends A {
	start(k: number): void {
		super.start(k);
		this.n += 1;
	}
}
const b = new B();
b.start(4);
console.log(b.n.toString());

class P {
	v(): int32 { return 1; }
	name(): string { return "base"; }
}
class Q extends P {
	v(): int32 { return super.v() + 10; }
	name(): string { return super.name() + "+mid"; }
}
class R extends Q {
	v(): int32 { return super.v() + 10; }
	name(): string { return super.name() + "+top"; }
}
const q: P = new Q();
const r: P = new R();
console.log(`${q.v()} ${r.v()} ${r.name()}`);

class G { m(): string { return "A.m"; } }
class H extends G {}
class I extends H { m(): string { return super.m() + " via grand"; } }
console.log(new I().m());

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	get(): T { return this.v; }
}
class IntBox extends Box<int32> {
	constructor(v: int32) { super(v); }
	show(): string { return `${super.get()} got`; }
}
console.log(new IntBox(7).show());
