import { assertFmtLossless } from "../roundtrip";

test "fmt: a for-of array pattern stays a pattern" {
	assert assertFmtLossless("for (const [r0, r1] of rows) {\n\tg(r0, r1);\n}\n");
}

test "fmt: a for-of object pattern with rest stays a pattern" {
	assert assertFmtLossless("for (const { id: rid, ...r } of rows) {\n\tg(rid, r);\n}\n");
}
