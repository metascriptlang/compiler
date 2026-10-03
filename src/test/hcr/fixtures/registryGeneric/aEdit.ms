import { echo } from "./cell";

export function runA(): string {
	const text = echo<string>("new");
	return text + echo<int64>(9).toString();
}
