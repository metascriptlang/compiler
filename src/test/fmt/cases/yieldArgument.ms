// The argument of `yield`.
//
// Symptom:    `yield i * 10` formatted to `yield (i * 10)`; the lossless check
//             refused every generator that yields an operator expression.
// Root cause: printYieldExpr printed the argument through printAtom, which
//             parenthesizes an operator expression; `yield` binds looser than any
//             operator, so no argument needs the parentheses.
// Fix:        the argument prints as a plain expression; written parentheses stay.

import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

const GEN = "function* g(): Iterator<int32> { for (let i: int32 = 0; i < 3; i++) { ";

test "fmt: yield of an operator expression adds no parentheses" {
	assert assertFmtLossless(GEN + "yield i * 10; } }");
	assert assertFmtLossless(GEN + "yield i > 1 ? i : 0; } }");
	assert assertFmtPreservesAst(GEN + "yield i * 10; } }");
}

test "fmt: written parentheses around a yield argument stay" {
	assert assertFmtLossless(GEN + "yield (i * 10); } }");
}

test "fmt: yield* keeps its delegate operand" {
	assert assertFmtLossless("function* h(): Iterator<int32> { yield 1; }\nfunction* g(): Iterator<int32> { yield* h(); }");
}
