export class Cell<T> {
	v: T;
	constructor(v: T) {
		this.v = v;
	}
	get(): T {
		return this.v;
	}
}

export function hold<T>(v: T): [() => T, (next: T) => void] {
	const c = new Cell<T>(v);
	return [(): T => c.get(), (next: T): void => { c.v = next; }];
}
