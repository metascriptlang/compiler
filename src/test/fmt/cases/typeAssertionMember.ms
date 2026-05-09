// Parens around `as` expression in member-access position.
//
// Symptom:    `(x as T).field` formats to `x as T.field` — the parens
//             vanish, and `.field` binds to `T` (the type) instead of
//             the assertion result. Re-parsing yields a different AST.
// Root cause: src/compiler/fmt/printer/expressions.ms:printMemberExpr
//             prints `d.object` directly, never asking whether the
//             object's kind needs wrapping. TypeAssertion has lower
//             precedence than member-access in the source grammar.
// Fix:        Wrap object in `(...)` when it's a TypeAssertion.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: (x as T).field preserves parens" {
	assertFmtPreservesAst("const a = (x as IdentifierData).name;");
}
