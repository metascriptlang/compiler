// @stdout: sub u=3 n=20 total=23 get=3 read=3 | leaf get=5 m=3 read=5 twice=6,15 | pair get=7 read=7 tag=p | str get=xq | plain get=9 base=9
// note: a class extending an instance of a generic class, `Sub extends Base<int32>`, a generic `Pair<U> extends Base<U>`, two levels below the instance with a plain override between the two, and a generic class extending a plain one: the subclass passes where the instance is expected, reaches the instance's methods and fields, and its `super(...)` runs the instance's constructor. Same output on C and JS.

class Base<U> {
	u: U;
	constructor(u: U) { this.u = u; }
	get(): U { return this.u; }
}

class Sub extends Base<int32> {
	n: int32;
	constructor(u: int32) { super(u + 1); this.n = u * 10; }
	total(): int32 { return this.u + this.n; }
	twice(): int32 { return this.u * 2; }
}

class Leaf extends Sub {
	m: int32 = 3;
	constructor(u: int32) { super(u); }
	twice(): int32 { return this.u * 3; }
}

class Pair<U> extends Base<U> {
	tag: string;
	constructor(u: U, tag: string) { super(u); this.tag = tag; }
}

class Plain {
	v: int32;
	constructor(v: int32) { this.v = v; }
	value(): int32 { return this.v; }
}

class Held<T> extends Plain {
	held: T;
	constructor(v: int32, held: T) { super(v); this.held = held; }
}

function read(b: Base<int32>): int32 { return b.get(); }
function plainOf(p: Plain): int32 { return p.value(); }
function twiceOf(s: Sub): int32 { return s.twice(); }

const s = new Sub(2);
const l = new Leaf(4);
const p = new Pair<int32>(7, "p");
const q = new Pair<string>("x", "q");
const h = new Held<string>(9, "h");
console.log(`sub u=${s.u} n=${s.n} total=${s.total()} get=${s.get()} read=${read(s)} | leaf get=${l.get()} m=${l.m} read=${read(l)} twice=${twiceOf(s)},${twiceOf(l)} | pair get=${p.get()} read=${read(p)} tag=${p.tag} | str get=${q.get()}${q.tag} | plain get=${h.value()} base=${plainOf(h)}`);
