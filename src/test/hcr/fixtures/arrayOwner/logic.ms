import { makeFirst } from "./first";
import { makeSecond, ownedLength } from "./second";

export function total(): int32 {
	const first = makeFirst(1);
	const second = makeSecond(2);
	let count: int32 = ownedLength(3);
	for (const cell of first) count += cell.text.length as int32;
	for (const cell of second) count += cell.text.length as int32;
	return count;
}
