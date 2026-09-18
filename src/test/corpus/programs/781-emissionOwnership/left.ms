import { Branch, score } from "./owner";
import { record } from "./state";
export function left(): Branch {
	return { label: "left", children: [{ label: "leaf", children: [] }] };
}
export function leftScore(): number { return score("left"); }
record("L");
