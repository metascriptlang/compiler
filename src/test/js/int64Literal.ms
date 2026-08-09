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

// Representation consistency: one switch selects BigInt or Number for EVERY
// int64 site on this backend. Selecting BigInt for the default initializer
// while literals and operators stayed Number made the first arithmetic op
// throw "Cannot mix BigInt and other types". Runtime coverage on both
// backends: corpus/programs/014-int64DefaultInit.ms.

test "uninitialized int64 defaults to the same representation as int64 literals" {
	const result = compileToJS("let a: int64;");
	assert result.ok;
	assert result.value.contains(" = 0;");
	assert !result.value.contains(" = 0n");
}

test "uninitialized uint64 defaults to the same representation as int64 literals" {
	const result = compileToJS("let u: uint64;");
	assert result.ok;
	assert result.value.contains(" = 0;");
	assert !result.value.contains(" = 0n");
}

test "uninitialized int64 array defaults to element zeros, not a BigInt array" {
	const result = compileToJS("let xs: int64[4];");
	assert result.ok;
	assert result.value.contains("[0, 0, 0, 0]");
	assert !result.value.contains("BigInt64Array");
}
