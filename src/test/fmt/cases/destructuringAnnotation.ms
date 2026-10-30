// A destructuring declaration keeps its type annotation.
//
// Symptom:    `const { x: v }: { x: string } = src;` formatted to `const { x: v } = src;`
//             and the checker then lost the declared type of the pattern.
// Fix:        the declaration carries destrType and typeExpr; the printer writes them after the pattern.

import { assertFmtContains, assertFmtIdempotent } from "../roundtrip";

test "fmt: object pattern annotation is kept" {
	assert assertFmtContains("const { x: v }: { x: string } = src;", "}: { x: string } = src");
}

test "fmt: array pattern annotation is kept" {
	assert assertFmtContains("const [a, b]: [int32, int32] = pair;", "]: [int32, int32] = pair");
}

test "fmt: annotated destructuring is idempotent" {
	assert assertFmtIdempotent("const { x: v }: { x: string } = src;");
}
