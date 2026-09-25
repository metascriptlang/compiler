type Wrap<T> = { inner: T };

class HolderA {
	w: Wrap<Wrap<int32>>;
	constructor() { this.w = { inner: { inner: 3 } }; }
}

export function fromA(): string {
	const h = new HolderA();
	return `${h.w.inner.inner}`;
}
