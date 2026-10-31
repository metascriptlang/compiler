// `sink` / `ref` / `out` / `readonly` parameters of arrow functions and function expressions.
// The parser lifts each modifier into the routine's flags (`arrowFlags`, `funcExprFlags`),
// so the printer has to spell them from there, as it does for a named function.

import { assertFmtPreservesAst, assertFmtContains } from "../roundtrip";

test "fmt: arrow function keeps sink, ref, out and readonly parameters" {
	const src = "const f = (sink a: Box, ref b: int32, out c: int32, readonly d: Box): void => {};";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "sink a: Box");
	assert assertFmtContains(src, "ref b: int32");
	assert assertFmtContains(src, "out c: int32");
	assert assertFmtContains(src, "readonly d: Box");
}

test "fmt: function expression keeps sink, ref, out and readonly parameters" {
	const src = "const f = function (sink a: Box, ref b: int32, out c: int32, readonly d: Box): void {};";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "sink a: Box");
	assert assertFmtContains(src, "ref b: int32");
	assert assertFmtContains(src, "out c: int32");
	assert assertFmtContains(src, "readonly d: Box");
}

test "fmt: async arrow function keeps a sink parameter" {
	const src = "const f = async (sink a: Box): Promise<void> => {};";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "async (sink a: Box)");
}
