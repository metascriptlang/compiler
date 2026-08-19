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

// ===== uint32 wrap =====
//
// C wraps mod 2^32 at this width and nowhere else — uint8/uint16 follow C's
// integer promotion on both backends already, and signed overflow traps on
// C-debug rather than producing a value. So every test here is uint32.

test "uint32 addition wraps" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a + b; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "uint32 subtraction wraps" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a - b; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "uint32 bitwise and wraps its result representation" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a & b; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "uint32 bitwise or wraps its result representation" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a | b; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "uint32 bitwise xor wraps its result representation" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a ^ b; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "uint32 complement wraps its result representation" {
	const result = compileToJS("function f(a: uint32): uint32 { return ~a; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "uint32 left shift wraps" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a << b; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

// A trailing mask cannot repair an arithmetic shift of the int32 view, so the
// operator itself is substituted. Asserting the absence of the signed form is
// the point: `(a >> b) >>> 0` would satisfy a naive ">>>" check while still
// returning 0xC0000000 for 0x80000000 >> 1.
test "uint32 right shift substitutes the unsigned operator" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a >> b; }");
	assert result.ok;
	assert result.value.contains(">>>");
	assert !result.value.contains(" >> ");
}

// The reference emits `(a * b) >>> 0` here and is measurably wrong against its
// own C backend once the product passes 2^53. docs/NIM-REF.md carries the row.
test "uint32 multiplication uses an exact 32-bit multiply" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a * b; }");
	assert result.ok;
	assert result.value.contains("Math.imul");
}

test "uint32 compound add wraps and loses the compound form" {
	const result = compileToJS("function f(b: uint32): uint32 { let a: uint32 = 1; a += b; return a; }");
	assert result.ok;
	assert result.value.contains(">>> 0");
	assert !result.value.contains("+=");
}

test "uint32 remainder is left alone" {
	const result = compileToJS("function f(a: uint32, b: uint32): uint32 { return a % b; }");
	assert result.ok;
	assert !result.value.contains(">>> 0");
}

// Signed arithmetic stays untouched: matching C-danger would mean inventing a
// wrap where C-debug traps instead of producing a value.
test "int32 addition is left alone" {
	const result = compileToJS("function f(a: int32, b: int32): int32 { return a + b; }");
	assert result.ok;
	assert !result.value.contains("| 0");
}

test "uint8 addition is left alone because C promotes it" {
	const result = compileToJS("function f(a: uint8, b: uint8): uint8 { return a + b; }");
	assert result.ok;
	assert !result.value.contains(">>> 0");
}
