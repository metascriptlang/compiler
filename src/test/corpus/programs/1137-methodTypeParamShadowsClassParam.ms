// @stdout: 1|x 1|true 1s|true2.5 m r false 3 4:n
// note: a method's own type parameter shadows the class parameter of the same name,
// whether inferred or explicit, crossed, static, returned inside the class, or constrained.
interface Named { name: string; }
class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	pair<T>(other: T): string { return `${this.v}|${other}`; }
	static make<T>(x: T): Box<T> { return new Box<T>(x); }
	rebox<T>(x: T): Box<T> { return new Box<T>(x); }
	label<T extends Named>(x: T): string { return `${this.v}:${x.name}`; }
}
class Two<T, U> {
	t: T; u: U;
	constructor(t: T, u: U) { this.t = t; this.u = u; }
	swap<U, T>(a: U, b: T): string { return `${this.t}${this.u}|${a}${b}`; }
}
const named: Named = { name: "n" };
const b = new Box<int32>(1);
const c = new Box<int32>(3);
console.log(b.pair("x"), b.pair<boolean>(true),
	new Two<int32, string>(1, "s").swap(true, 2.5),
	Box.make<string>("m").v, c.rebox("r").v, c.rebox<boolean>(false).v, c.v,
	new Box<int32>(4).label(named));
