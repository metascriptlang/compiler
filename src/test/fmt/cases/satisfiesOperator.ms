import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

test "fmt: satisfies prints its type after the operand" {
	assert assertFmtLossless("const s = { kind: \"circle\", size: 2 } satisfies Shape;\n");
}

test "fmt: satisfies chains with as and gains no parentheses" {
	assert assertFmtLossless("const k = x satisfies Kind as string;\n");
}

test "fmt: a binary operand of satisfies keeps its parentheses" {
	assert assertFmtPreservesAst("const a: int32 = 1; const c = (a + 1) satisfies int32;");
}

test "fmt: satisfies on the right of == keeps no added parentheses" {
	assert assertFmtLossless("const b = a == x satisfies T;\n");
}
