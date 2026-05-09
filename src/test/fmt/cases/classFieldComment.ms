// Trailing comments on class fields stay attached.
//
// Symptom:    Same as interface — class member comments hoisted to
//             after the closing `}` instead of staying inline.
// Fix:        printClassDecl pairs body comments to members by line,
//             using each member's node.location.line.

import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: class field with trailing comment preserves attachment" {
	const src = "class Foo {\n\ta: number = 1; // alpha\n\tb: number = 2; // beta\n}";
	assertFmtPreservesAst(src);
	assertFmtContains(src, "a: number = 1; // alpha");
	assertFmtContains(src, "b: number = 2; // beta");
}
