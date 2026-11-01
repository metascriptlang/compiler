// `sink` / `ref` / `out` parameters of arrow functions and function expressions.
// The parser lifts each modifier into the routine's flags (`arrowFlags`, `funcExprFlags`),
// so the printer has to spell them from there, as it does for a named function.

import { assertFmtPreservesAst, assertFmtContains } from "../roundtrip";

test "fmt: arrow function keeps sink, ref and out parameters" {
	const src = "const f = (sink a: Box, ref b: int32, out c: int32): void => {};";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "sink a: Box");
	assert assertFmtContains(src, "ref b: int32");
	assert assertFmtContains(src, "out c: int32");
}

test "fmt: function expression keeps sink, ref and out parameters" {
	const src = "const f = function (sink a: Box, ref b: int32, out c: int32): void {};";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "sink a: Box");
	assert assertFmtContains(src, "ref b: int32");
	assert assertFmtContains(src, "out c: int32");
}

test "fmt: async arrow function keeps a sink parameter" {
	const src = "const f = async (sink a: Box): Promise<void> => {};";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "async (sink a: Box)");
}
