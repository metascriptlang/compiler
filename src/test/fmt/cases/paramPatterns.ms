import { assertFmtLossless } from "../roundtrip";

test "fmt: a destructured function parameter stays a pattern" {
	assert assertFmtLossless("function f155({ a, b }: P155): string {\n\treturn b + a.toString();\n}\n");
}

test "fmt: a destructured parameter of a function returning an arrow stays a pattern" {
	assert assertFmtLossless("function greet({ name, n }: Item): () => string {\n\treturn () => name + n;\n}\n");
}

test "fmt: a destructured arrow parameter with an expression body keeps both" {
	assert assertFmtLossless("const pick = ([x, y]: int32[]) => x + y;\n");
}

test "fmt: a destructured method parameter stays a pattern" {
	assert assertFmtLossless("class C {\n\tm({ a }: P): int32 {\n\t\treturn a;\n\t}\n}\n");
}
