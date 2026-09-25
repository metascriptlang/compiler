class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
interface Pair<T> { first: T; second: T }
type Wrap<T> = { inner: T };

export function fromA(): string {
	const b = new Box<string>("a");
	const p: Pair<string> = { first: "p", second: "q" };
	const w: Wrap<string> = { inner: "w" };
	return `${b.v} ${p.first}${p.second} ${w.inner}`;
}
