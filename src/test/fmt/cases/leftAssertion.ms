import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

test "fmt: an as on the left of arithmetic and shifts gains no parentheses" {
	assert assertFmtLossless("const h = (bx as int32 / 256) | 0;\nconst mid = (lo + hi) as int32 >> 1;\n");
}

test "fmt: an as on the left of == gains no parentheses" {
	assert assertFmtLossless("function f(op: int32): boolean {\n\treturn op as number == 3;\n}\n");
}

test "fmt: an as before | keeps the parentheses a type would swallow" {
	assert assertFmtPreservesAst("const a: int32 = 1; const b: int32 = 2; const c = (a as int32) | b;");
}
