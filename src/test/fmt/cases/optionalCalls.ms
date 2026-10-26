import { assertFmtLossless } from "../roundtrip";

test "fmt: an optional call keeps its question dot" {
	assert assertFmtLossless("const a = f?.(1);\nconst b = o.f?.(1, 2);\n");
}

test "fmt: an optional index keeps its question dot" {
	assert assertFmtLossless("const a = xs?.[0];\nconst b = o.xs?.[i + 1]?.c;\n");
}
