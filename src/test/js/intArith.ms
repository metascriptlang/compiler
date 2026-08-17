// Integer division on the JS backend — docs/JS-NUMERIC.md.
//
// `/` is one operator over two meanings in MS: integer division when both
// operands are integer-typed, float division otherwise. Only the resolved type
// distinguishes them, so these compile real sources rather than fixtures.
//
// Runtime coverage for the values: corpus/programs/016-jsIntegerModel.ms.

import { compileToJS } from "../helpers";

test "int32 division truncates" {
	const result = compileToJS("function f(a: int32, b: int32): int32 { return a / b; }");
	assert result.ok;
	assert result.value.contains("| 0");
}

test "uint32 division shifts unsigned" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a / b; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "uint8 division masks to a byte" {
	const result = compileToJS("function f(a: uint8, b: uint8): uint8 { return a / b; }");
	assert result.ok;
	assert result.value.contains("& 255");
}

test "int64 division truncates through the global Math" {
	const result = compileToJS("function f(a: int64, b: int64): int64 { return a / b; }");
	assert result.ok;
	assert result.value.contains("Math.trunc");
}

test "float division is left alone" {
	const result = compileToJS("function f(a: float64, b: float64): float64 { return a / b; }");
	assert result.ok;
	assert !result.value.contains("| 0");
}

// Nim wraps `%` in Math.trunc; measured, that is a no-op once both operands are
// genuinely integral, and MS deliberately emits nothing. docs/NIM-REF.md carries
// the row. This test is what makes that divergence a decision rather than drift.
test "remainder is left alone" {
	const result = compileToJS("function f(a: int32, b: int32): int32 { return a % b; }");
	assert result.ok;
	assert !result.value.contains("| 0");
}

test "compound divide on an identifier truncates and loses the compound form" {
	const result = compileToJS("function f(b: int32): int32 { let a: int32 = 10; a /= b; return a; }");
	assert result.ok;
	assert result.value.contains("| 0");
	assert !result.value.contains("/=");
}

test "compound divide on a float is left alone" {
	const result = compileToJS("function f(b: float64): float64 { let a: float64 = 10.0; a /= b; return a; }");
	assert result.ok;
	assert result.value.contains("/=");
}
