import { assertFmtLossless, assertFmtPreservesAst, assertFmtIdempotent } from "../roundtrip";

test "fmt: a const and a let declaration list print as one statement" {
	const src = "const left = 1, right: int32 = 2;\nlet first = 3, second: int32;\n";
	assert assertFmtLossless(src);
	assert assertFmtPreservesAst(src);
	assert assertFmtIdempotent(src);
}

test "fmt: an exported list keeps one export keyword" {
	assert assertFmtLossless("export const base: int32 = 10, next: int32 = base + 1;\n");
}

test "fmt: a list inside a function and a case body" {
	assert assertFmtLossless("function f(k: int32): int32 {\n\tconst a = k, b = a + 1;\n\tswitch (k) {\n\t\tcase 1:\n\t\t\tconst lo = 8, hi = lo + 1;\n\t\t\treturn hi;\n\t}\n\treturn b;\n}\n");
}

test "fmt: a destructuring declarator then a plain one" {
	assert assertFmtLossless("const { x, y } = { x: \"x\", y: \"y\" }, total = 3;\n");
}
