export class Cell<T> {
	value: T;
	constructor(v: T) { this.value = v; }
}
export function holdNull<E>(e: E): string {
	const c = new Cell<E | null>(null);
	c.value = e;
	return c.value === null ? "null" : "set";
}
export function emptyCell<E>(e: E): string {
	const c = new Cell<E | null>(null);
	return c.value === null ? "null" : "set";
}
