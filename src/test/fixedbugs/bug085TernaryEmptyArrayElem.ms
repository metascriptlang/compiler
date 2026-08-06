// bug085 — `cond ? typedArray : []` left the empty branch typed Array<Inferred>
//
// Symptom:    the last pending-at-emission producer found by the B4 enumeration
//             (docs/UNKNOWN-BUG.md §8.4 item 4): an unannotated
//             `const xs = cond ? typed : []` kept Array<Inferred> on the `[]`
//             branch node, emitted the §4.1 msRefArray fallback silently, and
//             with the B4 seam armed became "internal: unresolved type reached
//             codegen" (three sites in actorLower.ms had the shape).
// Root cause: ConditionalExpr with no expected type checked both branches
//             independently and never re-fit the empty array literal against
//             the other branch. Nim fits BOTH branches to commonType.
// Fix:        retypeEmptyArrayBranch in the ConditionalExpr arm — the empty
//             literal adopts the other branch's concrete array type.

import { compileToC } from "../helpers";

test "bug085: unannotated `cond ? xs : []` compiles to C with the concrete element type" {
	const src = `function f(flag: boolean, xs: number[]): number {
	const picked = flag ? xs : [];
	return picked.length;
}
function main(): void { console.log(f(true, [1])); }
`;
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msNumberArray");
}

test "bug085: mirrored branches `cond ? [] : xs` also adopt the concrete type" {
	const src = `function f(flag: boolean, xs: number[]): number {
	const picked = flag ? [] : xs;
	return picked.length;
}
function main(): void { console.log(f(false, [1])); }
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug085: match arm empty array adopts the other arm's type" {
	const src = `function f(n: number, xs: number[]): number[] {
	const r = match (n) { 1 => xs, _ => [] };
	return r;
}
function main(): void { console.log(f(2, [7, 8]).length); }
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug085: both-empty ternary is a located checker error, not an internal one" {
	const src = `function f(flag: boolean): number {
	const both = flag ? [] : [];
	return both.length;
}
`;
	const c = compileToC(src);
	assert !c.ok;
	assert c.error.contains("cannot infer the element type");
	assert !c.error.contains("internal:");
}

test "bug085: bare empty array decl without annotation is a located checker error" {
	const src = `function main(): void {
	const x = [];
	x.push(1);
}
`;
	const c = compileToC(src);
	assert !c.ok;
	assert c.error.contains("cannot infer the element type");
	assert !c.error.contains("internal:");
}
