// bug532 — two object types of the same shape scored as a subtype, so a narrowed union member tied an overload
//
// Symptom:    `const d: D = { b: "s" }; make(K.B, d)` with `make(k: K.B, d: BData)` beside the
//             implementation `make(k: K, d: D)` reported "Ambiguous call to overloaded function 'make'"
//             once `d` narrowed to the union member `{ b: string }`; the compiler's own
//             `createNodeAt(NodeKind.X, data)` calls (8 sites) failed the same way, and each spent
//             about 20 s in the tie-break before reporting.
//
// Root cause: typeRelation's Struct arm answered Exact only for one Type object or one non-empty name,
//             so `BData` and the union's `{ b: string }` — the same anonymous shape, two objects — were
//             a Subtype: the overload scored Exact + Subtype, the implementation Subtype + Exact.
//
// Fix:        two object types relate exactly when sameType holds (anonymous shapes structurally), as
//             the reference's recordRel answers isEqual on sameType.

import { compileToC, compileToJS } from "../helpers";

const pre = "enum K532 { A, B }\n"
	+ "type D532 = { a: int32, x: { q: string } } | { b: string };\n"
	+ "type AData532 = { a: int32, x: { q: string } };\n"
	+ "type BData532 = { b: string };\n"
	+ "function make(k: K532.A, d: AData532): string;\n"
	+ "function make(k: K532.B, d: BData532): string;\n"
	+ "function make(k: K532, d: D532): string { return \"ok\"; }\n";

test "bug532: an initializer-narrowed union member resolves its overload" {
	const src = pre + "function f(): string {\n\tconst d: D532 = { b: \"s\" };\n\treturn make(K532.B, d);\n}\nconsole.log(f());\n";
	const c = compileToC(src);
	assert c.ok, c.error;
	const js = compileToJS(src);
	assert js.ok, js.error;
}

test "bug532: a member whose field is itself an object type resolves its overload" {
	const src = pre + "function f(): string {\n\tconst d: D532 = { a: 1, x: { q: \"s\" } };\n\treturn make(K532.A, d);\n}\nconsole.log(f());\n";
	const c = compileToC(src);
	assert c.ok, c.error;
}
