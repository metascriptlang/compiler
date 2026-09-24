class Box<K, V> {
	k: K;
	v: V;
	constructor(k: K, v: V) { this.k = k; this.v = v; }
}

export function fromC(): string {
	const b = new Box<string, int32>("k", 9);
	return `${b.k}${b.v}`;
}
