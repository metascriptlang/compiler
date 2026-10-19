const OFFSET: int32 = 2;

export class Box<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}

export function repeat<T>(value: T, count: int32): T {
	if (count == 0) return value;
	return repeat<T>(value, count - 1);
}

export function shifted<T>(value: T, offset: int32): int32 {
	const box = new Box<T>(value);
	return offset + OFFSET;
}
