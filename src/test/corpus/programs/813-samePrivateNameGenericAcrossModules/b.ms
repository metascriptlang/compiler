class Box {
	v: int32 = 3;
}
interface Pair { first: int32; second: int32 }
type Wrap = { inner: string };

export function fromB(): string {
	const b = new Box();
	const p: Pair = { first: 1, second: 2 };
	const w: Wrap = { inner: "z" };
	return `${b.v} ${p.first + p.second} ${w.inner}`;
}
