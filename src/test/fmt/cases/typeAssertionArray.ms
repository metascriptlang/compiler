// Parens around `as` expression in array-access (computed-member) base.
//
// Symptom:    `(arr as T[])[0]` formats to `arr as T[][0]` — the
//             `[0]` then gets absorbed into the type ascription
//             (`T[][0]` becomes a 0-element array type), and the
//             expression is no longer an array access at all.
// Fix:        printArrayAccess.array uses printAtom (wraps TypeAssertion).

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: (arr as T[])[0] preserves parens" {
	assert assertFmtPreservesAst("const a = (arr as Item[])[0];");
}
