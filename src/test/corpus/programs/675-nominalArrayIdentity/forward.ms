import { makeFirst } from "./first";
import { makeSecond } from "./second";

export function forwardLayout(): string {
	const first = makeFirst(1);
	const second = makeSecond(2);
	return (first[0].text.length as int32).toString() + " " + second[0].count.toString();
}
