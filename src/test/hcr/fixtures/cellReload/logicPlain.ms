import { keep, count } from "./holder";

export function step(): string {
	return "plain" + String(count());
}
