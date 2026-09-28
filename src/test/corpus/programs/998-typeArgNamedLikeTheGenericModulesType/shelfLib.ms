interface Item { a: int32; }

export class Shelf<T> {
	byName: Map<string, T> = new Map<string, T>();
	constructor() {}
	put(k: string, v: T): void { this.byName.set(k, v); }
	size(): int32 { return this.byName.size as int32; }
}

export class Rack<T> {
	slots: T[];
	constructor(first: T) {
		const init: T[] = [first];
		this.slots = init;
	}
}

export function libItem(): int32 { const i: Item = { a: 3 as int32 }; return i.a; }
