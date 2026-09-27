export class Bag<T> {
	items: T[];
	constructor() { this.items = []; }
	add(x: T): void {
		const next: T[] = this.items;
		next.push(x);
	}
	first(): T { return this.items[0]; }
}
