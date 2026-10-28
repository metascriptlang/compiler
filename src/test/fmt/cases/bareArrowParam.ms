import { assertFmtIdempotent, fmt } from "../roundtrip";

test "fmt: a bare arrow parameter gains parentheses" {
	assert fmt("set(c => c + 1);\n") == "set((c) => c + 1);\n";
}

test "fmt: a bare arrow with a block body gains parentheses" {
	assert fmt("const f = p => {\n\treturn p * 2;\n};\n") == "const f = (p) => {\n\treturn p * 2;\n};\n";
}

test "fmt: a nested bare arrow gains parentheses at each level" {
	assert fmt("const k = a => b => a + b;\n") == "const k = (a) => (b) => a + b;\n";
	assert fmt("const e = async p => p;\n") == "const e = async (p) => p;\n";
}

test "fmt: a typed or defaulted arrow parameter keeps its single pair of parentheses" {
	assert fmt("const t = (p: number) => p;\n") == "const t = (p: number) => p;\n";
	assert fmt("const d = (p = 1) => p;\n") == "const d = (p = 1) => p;\n";
	assert assertFmtIdempotent("set((c) => c + 1);\n");
}
