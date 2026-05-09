// Parens around `as` expression in new-callee position.
//
// Symptom:    `new (Ctor as T)()` formats to `new Ctor as T()` — parses
//             as `(new Ctor) as T()` instead of `new ((Ctor as T))()`.
//             The new-call binds to the wrong callee.
// Fix:        printNewExpr.callee uses printAtom (wraps TypeAssertion).

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: new (Ctor as T)() preserves parens" {
	assertFmtPreservesAst("const a = new (Ctor as Builder)();");
}
