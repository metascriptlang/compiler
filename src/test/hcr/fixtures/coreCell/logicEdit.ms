import { Bag } from "../box/box";

export function refill(b: Bag): void {
	b.items = [1, 2, 3];
}
