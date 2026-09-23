import { assertFmtLossless } from "../roundtrip";

test "fmt: typeof keeps the space before its operand" {
	assert assertFmtLossless("const v = 1;\nconst t = typeof v;\n");
}

test "fmt: void and delete keep the space before their operand" {
	assert assertFmtLossless("function f(o: any): void {\n\tvoid o.g();\n\tdelete o.k;\n}\n");
}
