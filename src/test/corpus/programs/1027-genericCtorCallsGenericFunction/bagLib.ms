function stash<T>(b: Bag<T>, x: T): void { b.items.push(x); }

export class Bag<T> {
	items: T[];
	constructor(xs: T[]) {
		this.items = [];
		for (const x of xs) { stash(this, x); }
	}
}
