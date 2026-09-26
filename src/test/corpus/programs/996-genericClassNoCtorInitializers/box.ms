export class Shelf<T> {
	label: string = "shelf";
	items: T[] = [];
	add(x: T): void { this.items.push(x); }
}
