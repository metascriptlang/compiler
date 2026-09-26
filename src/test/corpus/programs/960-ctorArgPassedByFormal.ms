// @stdout: a b a|a b|b b|3 2
// note: a constructor argument is passed the way the constructor's parameter is declared, as at any call: a string-literal union into a string parameter by value, a string into a union parameter by address (C passed each by the argument's type, which did not compile).

type Lit = "a" | "b";

class Box { m: string; constructor(m: string) { this.m = m; } }
class LitBox { l: Lit; constructor(l: Lit) { this.l = l; } }
class Holder { f: Lit = "a"; }
class GBox<T> { v: T; constructor(v: T) { this.v = v; } }
class Pair { xs: number[]; s: string; constructor(xs: number[], s: string) { this.xs = xs; this.s = s; } }

function pick(i: int32): Lit { return i == 0 ? "a" : "b"; }

function unionIntoString(l: Lit, i: int32, h: Holder): string {
	const k: Lit = pick(i);
	return new Box(l).m + " " + new Box(k).m + " " + new Box(h.f).m;
}

function stringIntoUnion(l: Lit): string {
	const fromLiteral: string = new LitBox("a").l;
	const fromParam: string = new LitBox(l).l;
	return fromLiteral + " " + fromParam;
}

function generic(l: Lit): string {
	const s: string = new GBox<string>(l).v;
	const u: string = new GBox<Lit>(l).v;
	return s + " " + u;
}

function arrays(xs: number[]): string {
	return new GBox<number[]>([1, 2, 3]).v.length.toString() + " " + new Pair(xs, "q").xs.length.toString();
}

function run(): string {
	return unionIntoString("a", 1, new Holder()) + "|" + stringIntoUnion("b") + "|" + generic("b") + "|" + arrays([4, 5]);
}
console.log(run());
