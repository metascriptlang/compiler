export interface Pair { a: int32; b: string; }
export let items: int32[] = [1, 2];
export let pair: Pair = { a: 1, b: "x" };
export function grow(): void {
	items.push(10);
	pair.a += 10;
}
