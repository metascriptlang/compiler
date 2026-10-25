import { Box } from "./box";
export interface Holder { grid: Box<int32>; }

export function makeHolder(): Holder {
	const box = new Box<int32>();
	box.items.push(1);
	box.items.push(2);
	return { grid: box };
}
