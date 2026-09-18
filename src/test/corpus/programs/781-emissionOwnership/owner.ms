import { record } from "./state";
export interface Branch { label: string; children: Branch[]; }
function privateBonus(): number { return 7; }
export function score<T>(value: T): number { return privateBonus(); }
record("O");
interface Held { label: string; }
let held: Held | null = null;
export function heldLabel(): string {
	if (held == null) held = { label: "held" };
	return held.label;
}
