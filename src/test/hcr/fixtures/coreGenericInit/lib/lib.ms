export class Box<T> {
	value: T;
	constructor(value: T) { this.value = value; }
	get(): T { return this.value; }
}
export class Tagged<T> extends Box<T> {
	tag: string;
	constructor(value: T, tag: string) {
		super(value);
		this.tag = tag;
	}
	label(): string { return `${this.tag}=${this.get()}`; }
}
export function libBox(): Box<int32> {
	return new Box<int32>(7);
}
export function libText(): Box<string> {
	return new Box<string>("lib");
}
export function libTagged(): Tagged<int32> {
	return new Tagged<int32>(3, "lib");
}
