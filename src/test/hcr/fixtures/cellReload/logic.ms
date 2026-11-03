import { keep, count } from "./holder";

export function step(): string {
	keep([{ text: "g1-" + String(count()) }]);
	return "boxed";
}
