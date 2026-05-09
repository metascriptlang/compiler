// `extern function` and `function*` (generator) at top level.
//
// AUDIT-VERIFIED: `extern function printf(fmt: string): void;` formats
// to `function printf(fmt: string): void {}` — `extern` keyword
// stripped AND empty body added (parser stores extern fn with empty
// BlockStmt; printer doesn't know to emit semicolon-only form).

import { assertFmtPreservesAst, assertFmtContains } from "../roundtrip";

test "fmt: extern function preserves extern keyword" {
	const src = "extern function printf(fmt: string): void;";
	assertFmtPreservesAst(src);
	assertFmtContains(src, "extern function");
}

test "fmt: top-level generator preserves star" {
	const src = "function* gen(): number { yield 1; return 0; }";
	assertFmtPreservesAst(src);
	assertFmtContains(src, "function* gen");
}
