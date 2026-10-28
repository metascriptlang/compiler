import { Box, Item, keepBoxed, keepOne } from "./lib";

export function fillNames(seen: HashSet<string>, names: string[]): void {
	for (let i = 0; i < names.length; i++) seen.add(names[i]);
}
export function fillItems(into: Item[], items: Item[]): void {
	for (let i = 0; i < items.length; i++) keepOne(into, items[i]);
}
export function fillBox(b: Box, items: Item[]): void {
	for (let i = 0; i < items.length; i++) keepBoxed(b, items[i]);
}
