import { capture } from "./cell";

export function right(): string {
	const integer = capture<int32>(8);
	const text = capture<string>("before");
	integer[1](10);
	text[1]("kept");
	return integer[0]().toString() + " " + text[0]();
}
