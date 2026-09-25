class Box<T> {
	tag: int32;
	w: T;
	constructor(w: T) { this.tag = 7; this.w = w; }
}
interface Pair<T> { count: int32; second: T; first: T }
type Wrap<T> = { pad: int32, inner: T };

export function fromB(): string {
	const b = new Box<string>("b");
	const p: Pair<string> = { count: 2, second: "s", first: "r" };
	const w: Wrap<string> = { pad: 4, inner: "x" };
	return `${b.tag}${b.w} ${p.count}${p.first}${p.second} ${w.pad}${w.inner}`;
}
