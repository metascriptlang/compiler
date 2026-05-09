// Property initializer printing.
//
// Symptom:    `foo: number = 1;` formats to `foo: number = ...;` —
//             the printer emits a literal `...` placeholder instead of
//             the actual initializer expression.
// Root cause: printPropertyDecl had a TODO that was never finished —
//             it always emits the literal text " = ...".
// Fix:        Emit `callPrintNode(d.propInitializer)` instead.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: class property with initializer" {
	assertFmtPreservesAst("class C { foo: number = 42; }");
}

test "fmt: class property with array initializer" {
	assertFmtPreservesAst("class C { items: number[] = []; }");
}
