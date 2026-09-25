type Wrap<T> = { tag: string, inner: T };

class HolderB {
	w: Wrap<Wrap<int32>>;
	constructor() { this.w = { tag: "o", inner: { tag: "i", inner: 9 } }; }
}

export function fromB(): string {
	const h = new HolderB();
	return `${h.w.tag}${h.w.inner.tag}${h.w.inner.inner}`;
}
