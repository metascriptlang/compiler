export class Box<T> {
	value: T;
	version: int32;
	constructor(value: T) {
		this.value = value;
		this.version = 1;
	}
}

export class Stamp<T> {
	count: int32 = 3;
}

export function make<T>(value: T): Box<T> {
	return new Box<T>(value);
}
