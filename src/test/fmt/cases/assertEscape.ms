// `assert <expr>, "message"` — message string must be re-escaped on
// emission. Otherwise embedded `"` or `\n` produces invalid syntax.
//
// AUDIT-VERIFIED: `assert true, "with \"quote\""` formats to
// `assert true, "with "quote""` which fails to parse.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: assert message with embedded quote re-escapes" {
	assert assertFmtPreservesAst("function f(): void { assert true, \"with \\\"quote\\\"\"; }");
}

test "fmt: assert message with newline re-escapes" {
	assert assertFmtPreservesAst("function f(): void { assert true, \"line1\\nline2\"; }");
}
