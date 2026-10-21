export class Link {
	next: Link | null = null;
	value: int32;
	constructor(value: int32) { this.value = value; }
}

export class Pair<A, B> {
	second: B;
	first: A;
	head: Link;
	constructor(first: A, second: B) {
		this.first = first;
		this.second = second;
		this.head = new Link(1);
	}
	describe(): string {
		return `${this.first}/${this.second}/${this.head.value}`;
	}
}
