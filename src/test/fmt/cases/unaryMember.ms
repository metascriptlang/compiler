// Parens around UnaryExpr in member-access object position.
//
// Symptom:    `(!x).toString()` formats to `!x.toString()` — the
//             negation now applies to the boolean result of toString,
//             flipping the semantics.
// Fix:        printAtom wraps UnaryExpr.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: (!x).toString() preserves parens" {
	assertFmtPreservesAst("const x: boolean = true; const s = (!x).toString();");
}
