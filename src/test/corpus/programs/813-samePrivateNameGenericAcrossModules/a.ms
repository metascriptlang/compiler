class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
interface Pair<T> { first: T; second: T }
type Wrap<T> = { inner: T };

export function fromA(): string {
	const b = new Box<int32>(7);
	const p: Pair<string> = { first: "x", second: "y" };
	const w: Wrap<boolean> = { inner: true };
	return `${b.v} ${p.first}${p.second} ${w.inner}`;
}
