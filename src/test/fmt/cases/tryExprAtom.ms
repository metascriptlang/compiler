// `try` expression in member-access object position.
//
// AUDIT-VERIFIED: `(try f() catch 0).toString()` formats to
// `try f() catch 0.toString()` — `0.toString()` parses as
// MemberExpr on a NumberLiteral, and the `try` ends up wrapping
// `f() catch <result>` instead of `<call>.toString()`.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: (try x catch y).z preserves parens" {
	assert assertFmtPreservesAst("function f(): string { return (try Result.ok(1) catch 0).toString(); }");
}
