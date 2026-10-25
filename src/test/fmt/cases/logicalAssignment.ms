import { assertFmtLossless, assertFmtContains, assertFmtIdempotent, assertFmtPreservesAst } from "../roundtrip";

test "fmt: each logical assignment keeps its operator" {
	assert assertFmtContains("let a: int32 | null = null;\na ??= 1;\n", "a ??= 1;");
	assert assertFmtContains("let a: int32 = 0;\na ||= 1;\n", "a ||= 1;");
	assert assertFmtContains("let a: int32 = 0;\na &&= 1;\n", "a &&= 1;");
}

test "fmt: a logical assignment on a field and an element is lossless and idempotent" {
	const source = "function f(o: Box, xs: int32[]): void {\n\to.x ??= 1;\n\txs[0] ||= 2;\n\to.y.z &&= 3;\n}\n";
	assert assertFmtLossless(source);
	assert assertFmtIdempotent(source);
}

test "fmt: a right side of lower precedence keeps its parens and a chain stays a chain" {
	assert assertFmtPreservesAst("let a: int32 = 0; let b: int32 = 0; a ||= (b = 1);");
	assert assertFmtPreservesAst("let a: int32 = 0; let b: int32 = 0; a ||= b &&= 1;");
	assert assertFmtPreservesAst("let a: int32 | null = null; let b: int32 = 0; a ??= b || 2;");
	assert assertFmtPreservesAst("let a: int32 | null = null; let b: int32 | null = null; a ??= (b ?? 2);");
}
