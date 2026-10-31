// A constructor parameter written with an accessibility or readonly modifier declares the field and
// assigns it before the field initializers run (TS parameter property). The program's stdout is the
// contract; the refusals live in handoff/paramProperty.ms.
// @stdout: public=1,2
// @stdout: private=7
// @stdout: protected=9
// @stdout: readonly=3
// @stdout: both=4,5
// @stdout: derived=10,20,30
// @stdout: default=5,8
// @stdout: mixed=t,3
// @stdout: optional=none,some
// @stdout: generic=5,x

class Pub {
	constructor(public a: int32, public b: int32) {}
}

class Priv {
	constructor(private n: int32) {}
	get(): int32 { return this.n; }
}

class Prot {
	constructor(protected n: int32) {}
}
class ProtChild extends Prot {
	read(): int32 { return this.n; }
}

class Ro {
	constructor(readonly n: int32) {}
}

class Both {
	constructor(private readonly x: int32, public readonly y: int32) {}
	sum(): int32 { return this.x + this.y - 4; }
	show(): string { return `${this.x},${this.y}`; }
}

class Base {
	constructor(public p: int32) {}
}
class Derived extends Base {
	constructor(p: int32, public q: int32, private r: int32) {
		super(p);
	}
	show(): string { return `${this.p},${this.q},${this.r}`; }
}

class Dflt {
	constructor(public a: int32 = 5, public b: int32 = 8) {}
}

class Mixed {
	tag: string = "t";
	constructor(public n: int32) {}
}

class Opt {
	constructor(public tag?: string) {}
	show(): string { return this.tag == null ? "none" : "some"; }
}

class Box<T> {
	constructor(public v: T) {}
}

const p = new Pub(1, 2);
console.log(`public=${p.a},${p.b}`);
console.log(`private=${new Priv(7).get()}`);
console.log(`protected=${new ProtChild(9).read()}`);
console.log(`readonly=${new Ro(3).n}`);
console.log(`both=${new Both(4, 5).show()}`);
console.log(`derived=${new Derived(10, 20, 30).show()}`);
console.log(`default=${new Dflt().a},${new Dflt(1, 8).b}`);
const m = new Mixed(3);
console.log(`mixed=${m.tag},${m.n}`);
console.log(`optional=${new Opt().show()},${new Opt("x").show()}`);
console.log(`generic=${new Box<int32>(5).v},${new Box<string>("x").v}`);
