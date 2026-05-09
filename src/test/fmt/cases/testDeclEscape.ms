// Escape sequences in `test "..."` names.
//
// Symptom:    `test "foo \"bar\" baz" { ... }` formats to
//             `test "foo "bar" baz" { ... }` — embedded quotes are
//             un-escaped, terminating the test name early. The result
//             fails to parse.
// Root cause: printTestDecl emits `q + d.testName + q` without ever
//             re-escaping `"` (or `'` if singleQuote) inside the name.
// Fix:        Escape the chosen quote character (and any backslash)
//             before emission.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: test name containing escaped double-quote" {
	assertFmtPreservesAst("test \"foo \\\"bar\\\" baz\" { assert true; }");
}
