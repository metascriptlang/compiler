let hits: int32 = 0;

export class Cell<T> {
	private value: T;

	constructor(value: T) {
		this.value = value;
	}

	get(): T {
		hits += 1;
		return this.value;
	}
}

export function hitCount(): int32 {
	return hits;
}

export function wrap<T>(value: T): Cell<T> {
	hits += 1;
	return new Cell<T>(value);
}
