import { Base } from "./base";
import type { Label } from "../support/label";
export class Child extends Base {
	constructor(value: int32) { super(value); }
	doubled(): int32 { return this.value * 2; }
}
export function increment(value: int32): int32 { return value + 1; }
export function readLabel(value: Label): string { return value.text; }
export const answer: int32 = 42;
