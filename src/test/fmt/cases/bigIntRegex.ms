// BigInt and Regex literals.
//
// Symptom:    `123n` and `/pat/g` formatted as `<unsupported node:N>`.
// Fix:        Add printBigIntLiteral / printRegexLiteral.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: bigint literal" {
	assert assertFmtPreservesAst("const a = 123n;");
}

test "fmt: regex literal" {
	assert assertFmtPreservesAst("const a = /hello/g;");
}
