// @stdout: 2|s 2|true 2:1 3
// note: a method's own type parameter read through Readonly<T> shadows the class parameter of the
// same name, inside a class instance whose body is built before emission and whose field is Readonly<T>.
class Box<T extends int32[]> {
	v: Readonly<T>;
	constructor(v: Readonly<T>) { this.v = v; }
	show<T>(other: Readonly<T>): string { return `${this.v.length}|${other}`; }
	count<T extends string[]>(xs: Readonly<T>): string { return `${this.v.length}:${xs.length}`; }
}
class Holder<T extends int32[]> {
	inner: Box<T>;
	constructor(inner: Box<T>) { this.inner = inner; }
}
const h = new Holder<int32[]>(new Box<int32[]>([1, 2]));
console.log(h.inner.show<string>("s"), h.inner.show(true), h.inner.count(["a"]), new Box<int32[]>([4, 5, 6]).v.length);
