import { assertFmtLossless } from "../roundtrip";

test "fmt: a for binding keeps its type annotation" {
	assert assertFmtLossless("for (let i: int32 = 0; i < 3; i += 1) {\n\tg(i);\n}\n");
}

test "fmt: a for binding keeps a generic type annotation" {
	assert assertFmtLossless("for (let m: Map<string, int64> = new Map(); m.size < 1; m.set(\"k\", 1)) {\n\tbreak;\n}\n");
}
