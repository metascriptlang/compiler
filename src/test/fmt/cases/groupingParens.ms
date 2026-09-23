import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

test "fmt: redundant grouping parentheses stay" {
	assert assertFmtLossless("function f(i: int32, n: int32): int32 {\n\treturn (i + 1 < n) ? i : n;\n}\n");
}

test "fmt: parentheses the grammar needs stay single" {
	assert assertFmtLossless("function f(w: int32, b: boolean): int32 {\n\treturn w - (b ? 2 : 0);\n}\n");
}

test "fmt: an arrow returning an object literal keeps its parentheses" {
	assert assertFmtLossless("const mk = (n: int32) => ({ n: n });\n");
}

test "fmt: a parenthesized operand of as keeps one pair" {
	assert assertFmtLossless("function f(acc: int32, x: int32): int32 {\n\tacc = (acc + x) as int32;\n\treturn acc;\n}\n");
}

test "fmt: grouping parentheses are stable" {
	assert assertFmtIdempotent("function f(a: int32, b: int32): int32 {\n\treturn (a) * (b + 1);\n}\n");
}

test "fmt: an as on the right of a compound assignment gains no parentheses" {
	assert assertFmtLossless("function f(acc: int32, x: int64): int32 {\n\tacc += x as int32;\n\treturn acc;\n}\n");
}
