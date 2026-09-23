import { assertFmtLossless } from "../roundtrip";

test "fmt: a bare arrow parameter gains no parentheses" {
	assert assertFmtLossless("set(c => c + 1);\n");
}

test "fmt: a bare arrow with a block body gains no parentheses" {
	assert assertFmtLossless("cell.setter(p => {\n\treturn p * 2;\n});\n");
}

test "fmt: a parenthesized single parameter keeps its parentheses" {
	assert assertFmtLossless("set((c) => c + 1);\n");
}
