interface Item { a: int32; }

export class Shelf<T> {
	byName: Map<string, T> = new Map<string, T>();
	constructor() {}
	put(k: string, v: T): void {
		const kept: T[] = [v];
		this.byName.set(k, kept[0]);
	}
	size(): int32 { return this.byName.size as int32; }
	read(k: string): T | null { return this.byName.get(k); }
}

export class Rack<T> {
	slots: T[];
	constructor(first: T) {
		const init: T[] = [first];
		this.slots = init;
	}
}

export function libItem(): int32 { const i: Item = { a: 3 as int32 }; return i.a; }

export function wrap<T>(value: T): T[] {
	const values: T[] = [];
	values.push(value);
	return values;
}

export function pairWith<T>(value: T): int32 {
	const own: Item = { a: 1 as int32 };
	const values: T[] = [value];
	return own.a + (values.length as int32);
}
