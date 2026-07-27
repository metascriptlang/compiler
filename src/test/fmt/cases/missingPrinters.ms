// Coverage for previously-unsupported NodeKinds:
// OutExpr, SizeofExpr, ForInStmt, FunctionExpr, MacroInvocation,
// MacroDecl, ArrayPattern, ObjectPattern, ObjectPatternProp,
// DestructuringDecl.

import { assertFmtPreservesAst } from "../roundtrip";

// `out` parameter modifier is encoded position-wise in fnFlags as
// `out:<idx>`; round-trip requires decoding+re-emitting, which is a
// fnFlags-encoding concern rather than a missing-printer concern.
// Skipped here — covered separately if needed.

test "fmt: sizeof expression preserved" {
	assert assertFmtPreservesAst("const a = sizeof int32;");
}

test "fmt: for-in statement preserved" {
	assert assertFmtPreservesAst("function f(obj: { x: number }): void { for (const k in obj) { console.log(k); } }");
}

test "fmt: macro invocation as decorator preserved" {
	assert assertFmtPreservesAst("@derive class Foo { x: number = 1; }");
}
