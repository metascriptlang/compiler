import { assertFmtLossless } from "../roundtrip";

test "fmt: a static local keeps static" {
	assert assertFmtLossless("function once(): string {\n\tstatic const t = mk(\"A\");\n\treturn t;\n}\n");
}

test "fmt: a static let local keeps static" {
	assert assertFmtLossless("function next(): int32 {\n\tstatic let n: int32 = 0;\n\tn += 1;\n\treturn n;\n}\n");
}
