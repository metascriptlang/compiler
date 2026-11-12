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
class Held<T> {
	held: T | null = null;
	tags: string[] = [];
}
function hold<T>(v: T): Held<T> {
	const h = new Held<T>();
	h.held = v;
	h.tags.push("t");
	return h;
}
export function libHeld(): string {
	const b = new Held<boolean>();
	b.held = true;
	return `${b.held === true} ${hold<int32>(5).held}`;
}
