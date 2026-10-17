export class Cell<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}

export type Accessor<T> = distinct (() => T);

export function accessor<T>(read: () => T): Accessor<T> {
	return read as Accessor<T>;
}

export function make<T>(compute: (prev: T | null) => T): Accessor<T> {
	const cell = new Cell<T>(compute(null));
	return ((): T => cell.value) as Accessor<T>;
}

export function memo<T>(compute: (prev: T | null) => T): Accessor<T> {
	const cell = new Cell<T>(compute(null));
	return accessor((): T => cell.value);
}
