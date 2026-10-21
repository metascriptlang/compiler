export class Link {
	next: Link | null = null;
	value: int32;
	constructor(value: int32) { this.value = value; }
}

export class Box<T> {
	items: T[] = [];
	head: Link;
	constructor() { this.head = new Link(7); }
	length(): number {
		return this.items.length + this.head.value;
	}
}
