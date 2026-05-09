// Parens around BinaryExpr/Conditional inside Unary/Await/Yield operand.
//
// Symptom 1:  `!(a && b)` formats to `!a && b` — the negation now binds
//             only to `a`, so the whole result is `(!a) && b`.
// Symptom 2:  `-(a + b)` formats to `-a + b` — unary minus binds to `a`.
// Symptom 3:  `await (a ? b : c)` formats to `await a ? b : c` — the
//             ternary now wraps the await rather than receiving its
//             result.
// Fix:        printUnaryExpr.operand and AwaitExpr / YieldExpr / MoveExpr
//             use printAtom for the inner expression.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: !(a && b) preserves parens" {
	assertFmtPreservesAst("const a: boolean = true; const b: boolean = false; const x = !(a && b);");
}

test "fmt: -(a + b) preserves parens" {
	assertFmtPreservesAst("const a: number = 1; const b: number = 2; const x: number = -(a + b);");
}
