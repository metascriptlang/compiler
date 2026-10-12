let made: int32 = 0;
let counted: int32 = 0;

function tag(): int32 {
	made += 1;
	return made;
}

export function wrap<T>(value: T): T[] {
	tag();
	return [value];
}

export function count<T>(value: T): T {
	counted += 1;
	return value;
}

function label(n: int32): string {
	return `#${n}`;
}

export function describe<T>(value: T): string {
	return label(made);
}

export class Box<T> {
	value: T;
	id: int32;
	constructor(value: T) {
		this.value = value;
		this.id = tag();
	}
	get(): T { return this.value; }
}

const own = new Box<string>("own");

export function ownBox(): unknown { return own; }

export function summary(): string {
	return `${own.get()} ${wrap("w").length} made=${made} counted=${counted}`;
}
