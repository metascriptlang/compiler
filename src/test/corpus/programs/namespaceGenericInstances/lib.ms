export function id<T>(x: T): T { return x; }

export function lastOf<T>(xs: T[]): T { return xs[xs.length - 1]; }

export class Shelf<T> {
	items: T[] = [];
	put(x: T): void { this.items.push(x); }
	top(): T { return lastOf(this.items); }
}
