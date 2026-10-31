// An arrow whose return type is a parenthesized function type, and an array of an inline tuple type, round-trip through fmt.

import { assertFmtPreservesAst, assertFmtContains, assertFmtIdempotent } from "../roundtrip";

test "fmt: arrow returning a parenthesized function type keeps its parentheses" {
	assert assertFmtContains("const make = (n: int32): ((x: int32) => int32) => (x: int32): int32 => x + n;", "((x: int32) => int32) =>");
	assert assertFmtPreservesAst("const make = (n: int32): ((x: int32) => int32) => (x: int32): int32 => x + n;");
	assert assertFmtIdempotent("const make = (n: int32): ((x: int32) => int32) => (x: int32): int32 => x + n;");
}

test "fmt: arrow returning a thunk type" {
	assert assertFmtPreservesAst("const weight = (a: number): (() => number) => { return () => a; };");
}

test "fmt: array of an inline tuple type" {
	assert assertFmtContains("const pairs: [string, string | null][] = [];", "[string, string | null][]");
	assert assertFmtPreservesAst("function count(pairs: [string, string][]): number { return pairs.length; }");
	assert assertFmtPreservesAst("const a: ([string, number] | null)[] = [];");
	assert assertFmtPreservesAst("const b: readonly [string, string][] = [];");
}
