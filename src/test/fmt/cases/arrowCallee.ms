// Parens around ArrowFunction in call-callee position (IIFE pattern).
//
// Symptom:    `(() => 1)()` formats to `() => 1()` — arrow body is now
//             `1()` (call on a number) instead of bare `1`.
// Fix:        printCallExpr.callee uses printAtom (wraps ArrowFunction).

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: IIFE (() => x)() preserves parens" {
	assertFmtPreservesAst("const a = (() => 1)();");
}
