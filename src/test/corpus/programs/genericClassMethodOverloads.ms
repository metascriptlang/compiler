// @stdout: 2 3|2 3 sx i3 5 q t
// note: overloads of a generic class's method, chosen by arity, by parameter type and with a
// type parameter of their own, each call the instance of the overload it picked.
class Nav<A> {
	go(a: int32): int32 { return a; }
	go(a: int32, b: int32): int32 { return a + b; }
}

class Pair<A, B> {
	tag: A;
	constructor(tag: A) { this.tag = tag; }
	go(a: int32): int32 { return a; }
	go(a: int32, b: int32): int32 { return a + b; }
	pick(a: string): string { return "s" + a; }
	pick(a: int32): string { return "i" + a.toString(); }
	wrap<T>(v: T): T { return v; }
	wrap<T>(v: T, w: T): T { return w; }
}

const n = new Nav<string>();
const p = new Pair<string, int32>("t");
console.log(n.go(2).toString() + " " + n.go(1, 2).toString() + "|" + p.go(2).toString() + " " + p.go(1, 2).toString()
	+ " " + p.pick("x") + " " + p.pick(3) + " " + p.wrap(5).toString() + " " + p.wrap("p", "q") + " " + p.tag);
