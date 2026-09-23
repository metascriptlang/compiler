import { assertFmtLossless } from "../roundtrip";

test "fmt: a comment after a bare block stays after it" {
	assert assertFmtLossless("function f(e: int32): int32 {\n\t{\n\t\tconst b = e;\n\t\tif (b > 0) {\n\t\t\treturn 1;\n\t\t}\n\t}\n\t// Catch-all\n\treturn 0;\n}\n");
}

test "fmt: a comment inside a bare block stays inside it" {
	assert assertFmtLossless("function f(): void {\n\t{\n\t\tg();\n\t\t// still inside\n\t}\n\th();\n}\n");
}
