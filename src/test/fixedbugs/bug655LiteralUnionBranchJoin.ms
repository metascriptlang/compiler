// bug655 — a string-literal union joined with another string printed `<object>` on C
//
// Symptom:    `const q = a ?? "N"` and `const c = a != null ? a : "N"` with `a: Align | null`
//             (`Align = "auto" | "center" | "stretch"`) printed `<object>` on C and the value
//             on JS.
// Root cause: the branch join widened a lone string literal to `string` but kept a literal
//             union as its members, so the result was a tagged union of four string slots
//             instead of a string.
// Fix:        branches that are all string-like and differ join to `string`, as two different
//             ranges join to their base type; the same literal union on both sides stays itself.

import { compileToC } from "../helpers";

const decls = "type Align = \"auto\" | \"center\" | \"stretch\";\nfunction pa(k: int32): Align | null { if (k == 1) return \"center\"; return null; }\nfunction pick(k: int32): Align { return k == 1 ? \"stretch\" : \"auto\"; }\n";

test "bug655: a literal union and another string join to a string" {
	const r = compileToC(decls + "function f(): string { const a = pa(1); const q = a ?? \"N\"; const c = a != null ? a : \"N\"; return q + c; }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert !r.value.contains("<object>"), r.value;
	assert !r.value.contains("msUnion_"), r.value;
}

test "bug655: the same literal union on both branches stays that union" {
	const r = compileToC(decls + "function f(k: int32): Align { const s = k == 1 ? pick(1) : pick(2); const keep: Align = s; return keep; }\n");
	assert r.ok, r.ok ? "" : r.error;
}
