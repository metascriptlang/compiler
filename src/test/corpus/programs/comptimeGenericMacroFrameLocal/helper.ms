import { describe, nameOf } from "./fields";

export function label<T>(value: T): string {
	return describe(value);
}

export function labelLocal<T>(value: T): string {
	const held = value;
	return describe(held);
}
