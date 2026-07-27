// Parens around ConditionalExpr in member-access object position.
//
// Symptom:    `(c ? a : b).field` formats to `c ? a : b.field` —
//             `.field` binds to `b` only; the ternary then evaluates
//             to either `a` (a different type) or `b.field`.
// Fix:        printAtom wraps ConditionalExpr.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: (c ? a : b).field preserves parens" {
	assert assertFmtPreservesAst("interface T { x: number; } const a: T = { x: 1 }; const b: T = { x: 2 }; const c: boolean = true; const v = (c ? a : b).x;");
}
