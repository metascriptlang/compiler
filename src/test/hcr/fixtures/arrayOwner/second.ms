import { Cell } from "./first";

export function makeSecond(n: int32): Cell[] {
	return [{ text: "gamma" + n }];
}

export function ownedLength(n: int32): int32 {
	let owned: Vec<Cell> = new Array(0);
	owned.push({ text: "delta" + n });
	let copied = owned;
	copied.push({ text: "epsilon" + n });
	return (owned.length + copied.length) as int32;
}
