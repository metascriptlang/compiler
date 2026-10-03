import { makeSecond } from "./second";
import { makeFirst } from "./first";

export function reverseLayout(): string {
	const second = makeSecond(2);
	const first = makeFirst(1);
	return second[0].count.toString() + " " + (first[0].text.length as int32).toString();
}
