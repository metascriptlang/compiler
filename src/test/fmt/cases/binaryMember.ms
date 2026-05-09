// Parens around BinaryExpr in member-access object position.
//
// Symptom:    `(a + b).toString()` formats to `a + b.toString()` —
//             `.toString()` binds to `b` only, leaving `a + <result>`,
//             which differs in evaluation and may type-error.
// Fix:        printAtom wraps BinaryExpr in `(...)`.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: (a + b).toString() preserves parens" {
	assertFmtPreservesAst("const a: number = 1; const b: number = 2; const s = (a + b).toString();");
}
