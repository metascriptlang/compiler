// `unreachable;` statement printing.
//
// Symptom:    `unreachable;` in source becomes `<unsupported node: 52>`
//             after fmt. NodeKind.UnreachableStmt has no printer.
// Fix:        Add NodeKind.UnreachableStmt → emit `unreachable;`.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: unreachable statement" {
	assert assertFmtPreservesAst("function f(): number { unreachable; }");
}
