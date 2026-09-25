// bug527 — a variant narrowing survived a write to the object it was read through or to its index
//
// Symptom:    `if (b.d.kind == K.Str) { b = numBox(); b.d.text }` and
//             `if (xs[i].kind == K.Str) { i = 1; xs[i].text }` passed the checker; C read the Num
//             payload as a string and crashed, JS printed undefined.
//
// Root cause: narrowByAssignment dropped a fact only when the written location was the narrowed
//             reference itself; a write to its object prefix or to an index it reads walked past.
//
// Fix:        a write whose target occurs inside the reference below its top (object prefix, index
//             variable, destructuring element, `++`/`--`) drops the fact to the declared type, the
//             reference's invalidateFacts over hasSubTree.

import { hasError, errorCount } from "../handoff/helpers";

const DU527 = "enum K527 { Num, Str }\n"
	+ "type D527 = match (kind: K527) { K527.Num => { a: int64 }, K527.Str => { text: string } };\n";
const BOX527 = DU527 + "class Box527 { d: D527 = { kind: K527.Str, text: \"s\" }; tag: int32 = 0; }\n";
const NARROW527 = "exists only on some variants";

test "bug527: assigning the object a variant was read through drops the narrowing" {
	assert hasError(BOX527 + "function f(first: Box527, other: Box527): string {\n"
		+ "\tlet b = first;\n"
		+ "\tif (b.d.kind == K527.Str) { b = other; return b.d.text; }\n"
		+ "\treturn \"\";\n}\n", NARROW527);
}

test "bug527: assigning a deeper prefix drops the narrowing" {
	assert hasError(BOX527 + "class Outer527 { inner: Box527 = new Box527(); }\n"
		+ "function f(o: Outer527, other: Box527): string {\n"
		+ "\tif (o.inner.d.kind == K527.Str) { o.inner = other; return o.inner.d.text; }\n"
		+ "\treturn \"\";\n}\n", NARROW527);
}

test "bug527: assigning or stepping the index variable drops the element narrowing" {
	assert hasError(DU527 + "function f(xs: D527[]): string {\n"
		+ "\tlet i: int32 = 0;\n"
		+ "\tif (xs[i].kind == K527.Str) { i = 1; return xs[i].text; }\n"
		+ "\treturn \"\";\n}\n", NARROW527);
	assert hasError(DU527 + "function f(xs: D527[]): string {\n"
		+ "\tlet i: int32 = 0;\n"
		+ "\tif (xs[i].kind == K527.Str) { i++; return xs[i].text; }\n"
		+ "\treturn \"\";\n}\n", NARROW527);
}

test "bug527: a write beside the narrowed reference keeps the narrowing" {
	assert errorCount(BOX527 + "function f(b: Box527, xs: D527[]): string {\n"
		+ "\tlet i: int32 = 0;\n"
		+ "\tlet j: int32 = 0;\n"
		+ "\tif (b.d.kind == K527.Str && xs[i].kind == K527.Str) { b.tag = 3; j = j + 1; return b.d.text + xs[i].text; }\n"
		+ "\treturn \"\";\n}\n") == 0;
}
