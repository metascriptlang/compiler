// Template literal printing.
//
// Symptom:    `\`Expected ${x}, got '${y}'\`` formats to mangled output —
//             the printer's `extractRawStringToken` helper, called for
//             each StringLiteral in the desugared concat tree, sees the
//             embedded single quote inside the backtick template and
//             "scans" forward looking for a closing quote. It scoops up
//             the rest of the source.
// Root cause: `extractRawStringToken` assumes any `"` or `'` at the
//             node's location is a real string-literal token boundary.
//             Template-derived StringLiteral nodes have positions that
//             point INTO the backtick template, where embedded quotes
//             are part of the content, not delimiters.
// Fix:        Skip raw-extract for StringLiteral nodes whose preceding
//             character isn't a plausible string-literal start
//             (whitespace / open-bracket / operator). Falls back to the
//             re-escape path which works correctly on the AST value.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: template literal with embedded single quotes" {
	assertFmtPreservesAst("function f(got: string, line: number): string { return `expected, got '${got}' at line ${line}`; }");
}

test "fmt: simple template literal" {
	assertFmtPreservesAst("function f(name: string): string { return `hello ${name}!`; }");
}
