// Default parameter values on class methods.
//
// AUDIT-VERIFIED: `class Foo { greet(name: string = "world") {} }`
// formats to `class Foo { greet(name: string) {} }` — defaults
// silently dropped. Root cause: MethodDeclData has no
// `methodDefaults` field, so the parser captures the defaults but
// then discards them.

import { assertFmtPreservesAst, assertFmtContains } from "../roundtrip";

test "fmt: class method default literal preserved" {
	const src = "class Foo { greet(name: string = \"world\"): string { return name; } }";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "name: string = \"world\"");
}

test "fmt: class method default expression preserved" {
	const src = "class Foo { compute(a: number, b: number = 1): number { return a + b; } }";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "b: number = 1");
}
