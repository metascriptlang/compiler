// Single-statement block stays on one line when it fits.
//
// Symptom:    `if (x) { return 1; }` (~25 chars) fmt to 3 lines:
//             `if (x) {\n  return 1;\n}`. Same for `for`, `while`,
//             arrow body, etc.
// Root cause: printBlock uses docHardLine unconditionally, forcing
//             multi-line even when content + braces fit printWidth.
// Fix:        Use docLine (flattenable) when the block has exactly
//             one short statement; docHardLine only for multi-stmt or
//             when content overflows printWidth.

import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: short if-block stays one line" {
	assert assertFmtPreservesAst("function f(x: number): number { if (x === 0) { return 1; } return x; }");
	assert assertFmtContains(
		"function f(x: number): number { if (x === 0) { return 1; } return x; }",
		"if (x === 0) { return 1; }",
	);
}
