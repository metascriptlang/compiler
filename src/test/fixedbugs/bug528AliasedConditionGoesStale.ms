// bug528 — a condition stored in a const kept narrowing a variable written after the const
//
// Symptom:    `const isStr = d.kind == K.Str; d = { kind: K.Num, … }; if (isStr) { d.text }` passed
//             the checker; C read the Num payload as a string and crashed, JS printed undefined.
//
// Root cause: getAliasedCondition checked only that the alias was a const, never that the narrowed
//             reference still held the value the alias was computed from.
//
// Fix:        the alias narrows a reference only when no write to it (itself, its object prefix, an
//             index it reads) lies on any path between the alias declaration and the test; a const
//             binding needs no walk.

import { hasError, errorCount } from "../handoff/helpers";

const DU528 = "enum K528 { Num, Str }\n"
	+ "type D528 = match (kind: K528) { K528.Num => { a: int64 }, K528.Str => { text: string } };\n";
const NARROW528 = "exists only on some variants";

test "bug528: a write after the alias drops its narrowing" {
	assert hasError(DU528 + "function f(first: D528, other: D528, flag: boolean): string {\n"
		+ "\tlet d: D528 = first;\n"
		+ "\tconst isStr = d.kind == K528.Str;\n"
		+ "\tif (flag) { d = other; }\n"
		+ "\tif (isStr) { return d.text; }\n"
		+ "\treturn \"\";\n}\n", NARROW528);
}

test "bug528: a write to a field the alias was read through drops its narrowing" {
	assert hasError(DU528 + "class Box528 { d: D528 = { kind: K528.Str, text: \"s\" }; }\n"
		+ "function f(b: Box528, other: D528): string {\n"
		+ "\tconst isStr = b.d.kind == K528.Str;\n"
		+ "\tb.d = other;\n"
		+ "\tif (isStr) { return b.d.text; }\n"
		+ "\treturn \"\";\n}\n", NARROW528);
}

test "bug528: a write on the loop back edge drops the narrowing inside the loop" {
	assert hasError(DU528 + "function f(xs: D528[]): string {\n"
		+ "\tlet d: D528 = xs[0];\n"
		+ "\tconst isStr = d.kind == K528.Str;\n"
		+ "\tlet out = \"\";\n"
		+ "\tfor (const x of xs) { if (isStr) { out = out + d.text; } d = x; }\n"
		+ "\treturn out;\n}\n", NARROW528);
}

test "bug528: an alias computed after the last write, or over a const, keeps narrowing" {
	assert errorCount(DU528 + "function f(first: D528, second: D528): string {\n"
		+ "\tlet d: D528 = first;\n"
		+ "\td = second;\n"
		+ "\tconst isStr = d.kind == K528.Str;\n"
		+ "\tconst fixed: D528 = first;\n"
		+ "\tconst fixedStr = fixed.kind == K528.Str;\n"
		+ "\tlet out = \"\";\n"
		+ "\tif (isStr) { out = out + d.text; }\n"
		+ "\tif (fixedStr) { out = out + fixed.text; }\n"
		+ "\treturn out;\n}\n") == 0;
}
