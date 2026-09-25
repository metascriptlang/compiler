// bug531 — a variant narrowing survived a call that received the narrowed value by address
//
// Symptom:    `if (d.kind == K.Str) { setNum(d); d.text }` with `setNum(ref x: D)` passed the
//             checker, as did `fill(out d)` and `xs.splice(0, 1)` before `xs[0].text`; the read took
//             the Str payload of a value the call had rewritten.
//
// Root cause: the binder built no flow node for a call, so nothing between the test and the read
//             could drop the fact.
//
// Fix:        a call is a flow node; an argument passed to a `ref`/`out` parameter, and the array
//             a mutating array method runs on, drop every fact about themselves and what sits below
//             them (the reference's invalidateFacts for a var argument). A by-value argument keeps
//             the fact.

import { hasError, errorCount } from "../handoff/helpers";

const DU531 = "enum K531 { Num, Str }\n"
	+ "type D531 = match (kind: K531) { K531.Num => { a: int64 }, K531.Str => { text: string } };\n"
	+ "function setNum531(ref x: D531): void { x = { kind: K531.Num, a: 3 }; }\n";
const NARROW531 = "exists only on some variants";

test "bug531: a local passed to a ref or out parameter loses its narrowing" {
	assert hasError(DU531 + "function f(first: D531): string {\n"
		+ "\tlet d: D531 = first;\n"
		+ "\tif (d.kind == K531.Str) { setNum531(d); return d.text; }\n"
		+ "\treturn \"\";\n}\n", NARROW531);
	assert hasError(DU531 + "function fill531(out x: D531): void { x = { kind: K531.Num, a: 3 }; }\n"
		+ "function f(first: D531): string {\n"
		+ "\tlet d: D531 = first;\n"
		+ "\tif (d.kind == K531.Str) { fill531(out d); return d.text; }\n"
		+ "\treturn \"\";\n}\n", NARROW531);
}

test "bug531: a field passed to a ref parameter loses its narrowing" {
	assert hasError(DU531 + "struct Holder531 { d: D531; }\n"
		+ "function f(first: D531): string {\n"
		+ "\tlet h: Holder531 = { d: first };\n"
		+ "\tif (h.d.kind == K531.Str) { setNum531(h.d); return h.d.text; }\n"
		+ "\treturn \"\";\n}\n", NARROW531);
}

test "bug531: a mutating array method drops the narrowing of an element" {
	assert hasError(DU531 + "function f(xs: D531[]): string {\n"
		+ "\tif (xs[0].kind == K531.Str) { xs.splice(0, 1); return xs[0].text; }\n"
		+ "\treturn \"\";\n}\n", NARROW531);
}

test "bug531: a by-value argument keeps the narrowing" {
	assert errorCount(DU531 + "function show531(x: D531): int32 { return x.kind == K531.Str ? 1 : 0; }\n"
		+ "function f(first: D531, xs: D531[]): string {\n"
		+ "\tlet d: D531 = first;\n"
		+ "\tif (d.kind == K531.Str && xs[0].kind == K531.Str) { show531(d); show531(xs[0]); return d.text + xs[0].text; }\n"
		+ "\treturn \"\";\n}\n") == 0;
}
