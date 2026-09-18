import { Branch, score } from "./owner";
import { record } from "./state";
export function right(): Branch { return { label: "right", children: [] }; }
export function rightScore(): number { return score(42); }
record("R");
