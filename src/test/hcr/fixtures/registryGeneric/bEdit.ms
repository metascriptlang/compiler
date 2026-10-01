import { echo } from "./cell";

export function runB(): string {
	const text = echo<string>("b");
	return text + echo<int32>(8).toString();
}
