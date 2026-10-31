import { holds, bytesOf } from "./lib";

export function label(): string {
	return holds("xy") + holds(bytesOf());
}
