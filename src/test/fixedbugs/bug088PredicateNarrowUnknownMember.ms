// bug088 — predicate-narrowed `unknown` member access emitted a void* deref on C
//
// Symptom:    `function isBox(u: unknown): u is Box` then `if (isBox(u)) { u.n }`
//             emitted `(*u_1_).n` with `void* u_1_` — clang: "member reference
//             base type 'void' is not a structure or union". The `(u as Box).n`
//             spelling inside the narrowed branch died the same way (the narrow
//             consumes the assertion as a no-op). Boolean-only use of the
//             predicate was always fine. Filed in Neon BUGS.md §2 (B4 audit).
// Root cause: the hidden deref trusts the flow-narrowed nodeType for
//             pointer-ness but emits the operand in its DECLARED repr (void*),
//             and nobody inserts the pointer cast the narrow implies.
// Fix:        at the HiddenDeref emission, when the declared symbol repr is
//             void* and the narrowed nodeType has a concrete pointer desc,
//             cast: `(*(Box*)u_1_)`.

import { compileToC } from "../helpers";

const localNarrow = "class Box { n: number; }\n"
	+ "function isBox(u: unknown): u is Box { return u !== null; }\n"
	+ "function main(): void {\n"
	+ "\tconst b = new Box();\n"
	+ "\tb.n = 7.0;\n"
	+ "\tconst u = b as unknown;\n"
	+ "\tif (isBox(u)) {\n"
	+ "\t\tconsole.log(u.n.toString());\n"
	+ "\t}\n"
	+ "}\n";

const castSpelling = "class Box { n: number; }\n"
	+ "function isBox(u: unknown): u is Box { return u !== null; }\n"
	+ "function main(): void {\n"
	+ "\tconst b = new Box();\n"
	+ "\tb.n = 7.0;\n"
	+ "\tconst u = b as unknown;\n"
	+ "\tif (isBox(u)) {\n"
	+ "\t\tconsole.log((u as Box).n.toString());\n"
	+ "\t}\n"
	+ "}\n";

const paramNarrow = "class Box { n: number; }\n"
	+ "function isBox(u: unknown): u is Box { return u !== null; }\n"
	+ "function readIt(u: unknown): number {\n"
	+ "\tif (isBox(u)) { return u.n; }\n"
	+ "\treturn 0.0;\n"
	+ "}\n"
	+ "function main(): void {\n"
	+ "\tconst b = new Box();\n"
	+ "\tb.n = 7.0;\n"
	+ "\tconsole.log(readIt(b as unknown).toString());\n"
	+ "}\n";

const booleanOnly = "class Box { n: number; }\n"
	+ "function isBox(u: unknown): u is Box { return u !== null; }\n"
	+ "function main(): void {\n"
	+ "\tconst b = new Box();\n"
	+ "\tconst u = b as unknown;\n"
	+ "\tconsole.log(isBox(u) ? \"yes\" : \"no\");\n"
	+ "}\n";

// A raw `(*<name>)` with no cast in between is the bug shape. Scoped to lines
// that actually dereference the narrowed name — a module-wide search for "void*"
// or "(*" passes for free on prelude code.
function hasUncastDeref(c: string, cname: string): boolean {
	for (const ln of c.split("\n")) {
		if (ln.contains("(*" + cname + ")")) return true;
	}
	return false;
}

test "bug088: narrowed local member read casts void* to the narrowed struct ptr" {
	const c = compileToC(localNarrow);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("(Box*)u_1_"), "no (Box*) cast on the narrowed local";
		assert !hasUncastDeref(c.value, "u_1_"), "raw (*u_1_) deref of a void* local survives";
	}
}

test "bug088: the (u as Box).n spelling gets the same cast" {
	const c = compileToC(castSpelling);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("(Box*)u_1_"), "no (Box*) cast in the cast spelling";
		assert !hasUncastDeref(c.value, "u_1_"), "raw (*u_1_) deref survives in the cast spelling";
	}
}

test "bug088: narrowed PARAM member read casts too" {
	const c = compileToC(paramNarrow);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("(Box*)u"), "no (Box*) cast on the narrowed param";
		assert !hasUncastDeref(c.value, "u"), "raw (*u) deref of a void* param survives";
	}
}

test "bug088 control: boolean-only predicate use emits no Box cast" {
	const c = compileToC(booleanOnly);
	assert c.ok;
	if (c.ok) {
		assert !c.value.contains("(Box*)u_1_"), "boolean-only use must not cast the local";
	}
}
