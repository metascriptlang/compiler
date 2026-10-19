export class Cell<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}

export function capture<T>(value: T): () => T {
	const cell = new Cell<T>(value);
	return (): T => cell.value;
}
