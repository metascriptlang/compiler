export interface Bag { values: string[]; }

export function recordBagValue(bag: Bag, value: string): void {
	bag.values.push(value);
}
