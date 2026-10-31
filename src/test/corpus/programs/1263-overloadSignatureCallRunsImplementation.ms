// @stdout: 0 10 21
// @stdout: s- s2 n-
// @stdout: f5 m5 c5 hnull x2
// @stdout: s:q:0 n:4:5
// @stdout: s:q:2 n:4:1.5
// @stdout: 3
// A call through an overload signature runs the implementation: a rest parameter the signature
// leaves out still arrives empty, an omitted argument takes the implementation's default before
// the signature's optional mark, a constructor signature's optional parameter may be omitted, and a
// super call ranks the base's signatures and converts each argument to the parameter it fills.
function f(a: string): number;
function f(a: string, ...xs: int32[]): number { return xs.length; }
class Counter {
	m(a: string): number;
	m(a: string, ...xs: int32[]): number { return xs.length + 10; }
}
struct Box { n: int32; }
function count(this b: Box, a: string): number;
function count(this b: Box, a: string, ...xs: int32[]): number { return xs.length + 20 + b.n; }
const box: Box = { n: 1 };
console.log(f("a"), new Counter().m("b"), box.count("c"));

class Optional {
	v: string;
	constructor(a: string, b?: int32);
	constructor(a: int32);
	constructor(a: string | int32, b?: int32) { this.v = (typeof a == "string" ? "s" : "n") + (b == null ? "-" : b.toString()); }
}
console.log(new Optional("x").v, new Optional("y", 2).v, new Optional(3).v);

function g(a: string, b?: int32): string;
function g(a: string, b: int32 | null = 5): string { return a + (b == null ? "null" : b.toString()); }
class Method {
	m(a: string, b?: int32): string;
	m(a: string, b: int32 | null = 5): string { return a + (b == null ? "null" : b.toString()); }
}
class Built {
	v: string;
	constructor(a: string, b?: int32);
	constructor(a: string, b: int32 | null = 5) { this.v = a + (b == null ? "null" : b.toString()); }
}
function h(a: string, b?: int32): string;
function h(a: string, b?: int32): string { return a + (b == null ? "null" : b.toString()); }
console.log(g("f"), new Method().m("m"), new Built("c").v, h("h"), g("x", 2));

class Base {
	v: string;
	constructor(a: string);
	constructor(a: int32, b: int32);
	constructor(a: string | int32, b: int32 = 0) { this.v = (typeof a == "string" ? "s:" + a : "n:" + a.toString()) + ":" + b.toString(); }
}
class FromString extends Base { constructor(x: string) { super(x); } }
class FromPair extends Base { constructor() { super(4, 5); } }
console.log(new FromString("q").v, new FromPair().v);

class Plain {
	v: string;
	constructor(a: string | int32, n: number) { this.v = (typeof a == "string" ? "s:" + a : "n:" + a.toString()) + ":" + n.toString(); }
}
class Narrow extends Plain { constructor(x: string, k: int32) { super(x, k); } }
class Literal extends Plain { constructor() { super(4, 1.5); } }
console.log(new Narrow("q", 2).v, new Literal().v);

class Held {
	constructor(x: int32);
	constructor(private x: int32) {}
	get(): int32 { return this.x; }
}
console.log(new Held(3).get());
