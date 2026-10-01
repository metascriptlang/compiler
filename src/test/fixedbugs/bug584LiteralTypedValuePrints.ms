// bug584 — a value of a literal type printed its type instead of its value
//
// Symptom:    with `const p: Pair<"x">`, `console.log(p.a)` printed `<x>` on C and JS;
//             `id<true>(true)` printed `<true>`, and an `id<K.A>(K.A)` printed `<K>`.
// Root cause: the toString lowering picks its path by the type's kind; a string, boolean or
//             enum member literal type matched none and fell to the `<TypeName>` placeholder.
// Fix:        a literal type prints through its base type (the reference prints a range value
//             through its base).

import { compileToC, compileToJS } from "../helpers";

const header = `
enum K { A, B }
struct Pair<T> { a: T; b: T; }
function id<T>(x: T): T { return x; }
`;

function printsPlaceholder(body: string, placeholder: string): boolean {
	const c = compileToC(header + body);
	const js = compileToJS(header + body);
	if (!c.ok || !js.ok) return true;
	return c.value.contains(placeholder) || js.value.contains(placeholder);
}

test "bug584: a string literal typed value prints its value" {
	assert !printsPlaceholder("const p: Pair<\"x\"> = { a: \"x\", b: \"x\" };\nconsole.log(p.a);\n", "\"<x>\"");
}

test "bug584: a boolean literal typed value prints its value" {
	assert !printsPlaceholder("const t = id<true>(true);\nconsole.log(t, `${t}`);\n", "\"<true>\"");
}

test "bug584: an enum member typed value prints as its enum" {
	assert !printsPlaceholder("const e = id<K.A>(K.A);\nconst u: Pair<K.B> = { a: K.B, b: K.B };\nconsole.log(e, u.a);\n", "\"<K>\"");
}
