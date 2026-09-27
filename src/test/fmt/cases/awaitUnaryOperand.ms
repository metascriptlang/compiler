// An `await` as the operand of a prefix operator is printed as written.
//
// Symptom: `!await f()` formatted to `!(await f())`, and the lossless check refused the file
//          ("fmt changes `await` into `(`").
// Fix:     `await e` is itself a unary-level expression, so printUnaryExpr prints it without
//          added parens; parens the source wrote stay through NodeFlag.Parenthesized.

import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

test "fmt: !await keeps the source tokens" {
	assert assertFmtLossless("async function f(): Promise<boolean> {\n\treturn true;\n}\nconst x = !await f();\n");
}

test "fmt: -await keeps the source tokens" {
	assert assertFmtLossless("async function f(): Promise<int32> {\n\treturn 1;\n}\nconst x = -await f();\n");
}

test "fmt: typeof await keeps the source tokens" {
	assert assertFmtLossless("async function f(): Promise<int32> {\n\treturn 1;\n}\nconst x = typeof await f();\n");
}

test "fmt: !(await f()) keeps the parens the source wrote" {
	assert assertFmtLossless("async function f(): Promise<boolean> {\n\treturn true;\n}\nconst x = !(await f());\n");
}

test "fmt: !await keeps the negation around the awaited value" {
	assert assertFmtPreservesAst("async function f(): Promise<boolean> { return true; }\nconst x = !await f();\n");
}
