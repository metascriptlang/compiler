import { assertFmtLossless } from "../roundtrip";

test "fmt: extern class keeps extern and its bodyless methods" {
	assert assertFmtLossless("extern class ClassList {\n\textern add(name: cstring): void;\n\textern item(i: int32): cstring from \"item_at\";\n}\n");
}

test "fmt: extern enum keeps extern" {
	assert assertFmtLossless("extern enum Mode {\n\tA,\n\tB,\n}\n");
}

test "fmt: opaque extern class keeps its keyword and native name" {
	assert assertFmtLossless("extern class FILE from \"FILE\";\n");
}

test "fmt: extern const keeps its keyword and type" {
	assert assertFmtLossless("extern const SEEK_END: int32;\n");
}

test "fmt: extern function with a body keeps the body" {
	assert assertFmtLossless("extern function f(): int32 {\n\treturn 1;\n}\n");
}

test "fmt: abstract method stays bodyless" {
	assert assertFmtLossless("export extern function g(): void;\nclass A {\n\tm(): void;\n}\n");
}
