// A quoted key of an object binding prints as written.
//
// Symptom:    `const { "a:b": v } = src;` formatted to `const { a:b: v } = src;`, which does not lex,
//             and `const { "x": v } = src;` to `const { x: v } = src;`, which the lossless check refuses.
// Fix:        the pattern prop reads its key from the source as an object literal key does (quotes
//             dropped only where the key is an identifier), and prints `{ x }` only where the source did.

import { assertFmtContains, assertFmtIdempotent } from "../roundtrip";

test "fmt: a quoted identifier binding key prints unquoted, as an object literal key does" {
	assert assertFmtContains("const { \"x\": v } = src;", "{ x: v }");
}

test "fmt: a binding whose alias repeats its key stays written out" {
	assert assertFmtContains("const { \"m\": m } = src;", "{ m: m }");
	assert assertFmtIdempotent("const { \"m\": m } = src;");
}

test "fmt: a quoted binding key that is no identifier keeps its quotes" {
	assert assertFmtContains("const { \"a:b;c\": v } = src;", "{ \"a:b;c\": v }");
}

test "fmt: a quoted parameter binding keeps its quotes" {
	assert assertFmtContains("function f({ \"a-b\": v }: Src): int32 { return v; }", "{ \"a-b\": v }");
}

test "fmt: quoted bindings are idempotent" {
	assert assertFmtIdempotent("const { \"x\": v, y } = src;");
}
