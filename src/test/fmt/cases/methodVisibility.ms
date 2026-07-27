// Visibility on class methods. Encoded in methodFlags string
// (`private|async|gen:T,U`) so no AST shape change required.

import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: private class method preserved" {
	const src = "class Foo { private bar(): void {} }";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "private bar");
}

test "fmt: protected static class method preserved" {
	const src = "class Foo { protected static baz(): number { return 0; } }";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "protected static baz");
}
