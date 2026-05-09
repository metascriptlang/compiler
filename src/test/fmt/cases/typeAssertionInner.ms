// Parens around the inner expression of a TypeAssertion.
//
// Symptom 1:  `(a + b) as T` formats to `a + b as T` — `as T` then
//             binds only to `b`, leaving `a + (b as T)` which has a
//             different evaluation tree.
// Symptom 2:  `(a ? b : c) as T` formats to `a ? b : c as T` — the
//             `as T` attaches to the alternate branch only, breaking
//             the cast intention.
// Fix:        printTypeAssertion.asExpr wraps low-precedence inner.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: (a + b) as T preserves parens" {
	assertFmtPreservesAst("const a: number = 1; const b: number = 2; const x = (a + b) as int32;");
}

test "fmt: (cond ? a : b) as T preserves parens" {
	assertFmtPreservesAst("const a: number = 1; const b: number = 2; const c: boolean = true; const x = (c ? a : b) as int32;");
}
