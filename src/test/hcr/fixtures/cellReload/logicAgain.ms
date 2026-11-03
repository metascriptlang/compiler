import { keep, count } from "./holder";

export function step(): string {
	keep([{ text: "g3-" + String(count()) }]);
	return "boxed";
}
