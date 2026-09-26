export class Box<T> {
	v: T;
	items: T[] = [];
	tag: string = "init";
	constructor(v: T) { this.v = v; }
	add(x: T): void { this.items.push(x); }
}
