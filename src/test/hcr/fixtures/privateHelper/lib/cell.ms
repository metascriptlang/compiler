let hits: int32 = 0;

function bump(n: int32): int32 {
	return n + 1;
}

function noop(): void {}

export class Cell<T> {
	private value: T;
	private done: () => void = noop;

	constructor(value: T) {
		this.value = value;
	}

	get(): T {
		hits = bump(hits);
		this.done();
		return this.value;
	}
}

export function hitCount(): int32 {
	return hits;
}

export function wrap<T>(value: T): Cell<T> {
	const step: (n: int32) => int32 = bump;
	hits = step(hits);
	return new Cell<T>(value);
}
