// int64 literal fidelity — source text → emitted JS.
//
// Sibling of src/test/c/int64Literal.ms: the truncation is in the front end
// (`NumberLiteralData.value` is a double), so it shows up identically here even
// though the JS backend could otherwise have copied the digits through verbatim.
//
// Keeping the digits is necessary but NOT sufficient on this backend: a JS
// number literal is still parsed as a double by the engine, so exact int64
// semantics additionally need the BigInt mapping (docs/JSON.md roadmap 3).
// These tests pin the front-end half, which that work builds on.

import { compileToJS } from "../helpers";

test "int64 literal above 2^53 keeps its digits in JS" {
	const result = compileToJS("const a: int64 = 9007199254740993;");
	assert result.ok;
	assert result.value.contains("9007199254740993");
}

test "int64 literal at int64 max keeps its digits in JS" {
	const result = compileToJS("const a: int64 = 9223372036854775807;");
	assert result.ok;
	assert result.value.contains("9223372036854775807");
}
