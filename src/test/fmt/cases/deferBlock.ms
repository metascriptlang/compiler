// `defer { … }` takes no semicolon: the parser reads the block and stops, so a
// `;` after it is a stray token. The printer appended one after every defer, and
// the second pass failed to parse (corpus deferBlockMethodCalls, guard
// solanaRaiseFlagLinks went UNSTABLE in the fmt lane, 2026-10-05).

import { assertFmtIdempotent, assertFmtPreservesAst } from "../roundtrip";

test "fmt: a defer block stays without a semicolon" {
	assert assertFmtIdempotent("function f(): void { const s = new Set<int32>(); { defer { s.add(7); } s.add(1); } }");
}

test "fmt: a defer expression keeps its semicolon" {
	assert assertFmtPreservesAst("function f(): void { defer g(); }\nfunction g(): void {}");
	assert assertFmtIdempotent("function f(): void { defer g(); }\nfunction g(): void {}");
}
