// int64 literal fidelity — source text → emitted JS.
//
// Sibling of src/test/c/int64Literal.ms: the digits have to survive the front
// end, where `NumberLiteralData.value` is a double and only `intVal` is exact.
//
// On this backend int64/uint64 ARE native BigInt, so keeping the digits is only
// half of it: every int64 site — literal, default initializer, typed array —
// has to pick the same representation, or the first arithmetic op throws
// "Cannot mix BigInt and other types". That mixing bug shipped once, when the
// default initializer emitted `0n` while literals stayed Numbers. Runtime
// coverage: corpus/programs/013-int64Fidelity.ms + 014-int64DefaultInit.ms.

import { compileToJS } from "../helpers";

test "int64 literal above 2^53 keeps its digits in JS" {
	const result = compileToJS("const a: int64 = 9007199254740993;");
	assert result.ok;
	assert result.value.contains("9007199254740993n");
}

test "int64 literal at int64 max keeps its digits in JS" {
	const result = compileToJS("const a: int64 = 9223372036854775807;");
	assert result.ok;
	assert result.value.contains("9223372036854775807n");
}

test "int64 literal is a BigInt literal, not a Number" {
	const result = compileToJS("const a: int64 = 5;");
	assert result.ok;
	assert result.value.contains("5n");
	assert !result.value.contains(" = 5;");
}

test "uninitialized int64 defaults to the same representation as int64 literals" {
	const result = compileToJS("let a: int64;");
	assert result.ok;
	assert result.value.contains(" = 0n");
}

test "uninitialized uint64 defaults to the same representation as int64 literals" {
	const result = compileToJS("let u: uint64;");
	assert result.ok;
	assert result.value.contains(" = 0n");
}

test "uninitialized int64 array is a BigInt64Array" {
	const result = compileToJS("let xs: int64[4];");
	assert result.ok;
	assert result.value.contains("BigInt64Array");
}

// A narrower integer reaching an int64 slot is widened at the boundary the
// checker marks, so no Number ever meets a BigInt operator.

test "int32 widened into an int64 slot becomes a BigInt" {
	const result = compileToJS("const i: int32 = 7; const a: int64 = i;");
	assert result.ok;
	assert result.value.contains("BigInt(");
}

test "int64 narrowed into an int32 slot becomes a Number" {
	const result = compileToJS("const a: int64 = 7; const i: int32 = a as int32;");
	assert result.ok;
	assert result.value.contains("Number(");
}

test "int64 division keeps no Math.trunc — BigInt division already truncates" {
	const result = compileToJS("const a: int64 = 7; const b: int64 = 2; const c: int64 = a / b;");
	assert result.ok;
	assert !result.value.contains("Math.trunc");
}
