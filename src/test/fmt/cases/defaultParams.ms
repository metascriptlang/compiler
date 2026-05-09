// Default parameter values on function declarations.
//
// Symptom:    `function f(x: string = "foo"): void {}` formats to
//             `function f(x: string): void {}` — the `= "foo"` clause
//             is silently dropped. Callers omitting the arg now fail
//             check with "Too few arguments".
// Root cause: printFunctionDecl iterates params + types but never
//             reads d.fnDefaults.
// Fix:        Emit ` = <init>` after each param whose fnDefaults entry
//             is non-null.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: function f(x: T = lit) preserves default" {
	assertFmtPreservesAst("function f(x: string = \"foo\"): string { return x; }");
}

test "fmt: function f(a, b = 0, c = \"hi\") mixed defaults" {
	assertFmtPreservesAst("function f(a: number, b: number = 0, c: string = \"hi\"): number { return a + b; }");
}
