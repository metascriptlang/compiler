export class Item { id: int32 = 0; }
export class Box { items: Item[] = []; }
export function make(k: int32): Item {
	const it = new Item();
	it.id = k;
	return it;
}
export function keepAll<T>(into: T[], from: T[]): void {
	for (let i = 0; i < from.length; i++) into.push(from[i]);
}
export function keepOne<T>(into: T[], x: T): void { into.push(x); }
export function keepBoxed(b: Box, it: Item): void { b.items.push(it); }
