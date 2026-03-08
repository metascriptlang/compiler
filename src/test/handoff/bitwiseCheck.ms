// Route 15: Checker — bitwise operator type safety
//
// Verifies: bitwise ops (&, |, ^, <<, >>, >>>, ~) require integer operands.
// Standard reference parity: bitwise ops only have integer overloads.
// Float/double/number types are rejected at the checker phase.

import { checkSource } from "./helpers";

// ===== Helper =====

function errorCount(src: string): number {
	const ctx = checkSource(src);
	if (ctx === null) return -1;
	return ctx.errors.length;
}

function hasError(src: string, needle: string): boolean {
	const ctx = checkSource(src);
	if (ctx === null) return false;
	let i = 0;
	while (i < ctx.errors.length) {
		if (ctx.errors[i].message.indexOf(needle) >= 0) return true;
		i = i + 1;
	}
	return false;
}

// ===== Valid: integer bitwise ops =====

test "int32 & int32 is valid" {
	const src = "const a: int32 = 0xFF as int32;\nconst b: int32 = 0x0F as int32;\nconst c = a & b;";
	assert errorCount(src) === 0;
}

test "uint8 | uint8 is valid" {
	const src = "const a: uint8 = 1 as uint8;\nconst b: uint8 = 2 as uint8;\nconst c = a | b;";
	assert errorCount(src) === 0;
}

test "int64 ^ int64 is valid" {
	const src = "const a: int64 = 1 as int64;\nconst b: int64 = 2 as int64;\nconst c = a ^ b;";
	assert errorCount(src) === 0;
}

test "int32 << int32 is valid" {
	const src = "const a: int32 = 1 as int32;\nconst b: int32 = 4 as int32;\nconst c = a << b;";
	assert errorCount(src) === 0;
}

test "int32 >> int32 is valid" {
	const src = "const a: int32 = 16 as int32;\nconst b: int32 = 2 as int32;\nconst c = a >> b;";
	assert errorCount(src) === 0;
}

// ===== Invalid: number (float64) bitwise ops =====

test "number & number errors" {
	assert hasError("const a: number = 1;\nconst b: number = 2;\nconst c = a & b;", "bitwise operator '&' requires integer type");
}

test "number | number errors" {
	assert hasError("const a: number = 1;\nconst b: number = 2;\nconst c = a | b;", "bitwise operator '|' requires integer type");
}

test "number << number errors" {
	assert hasError("const a: number = 1;\nconst b: number = 4;\nconst c = a << b;", "bitwise operator '<<' requires integer type");
}

test "number >> number errors" {
	assert hasError("const a: number = 8;\nconst b: number = 2;\nconst c = a >> b;", "bitwise operator '>>' requires integer type");
}

test "number ^ number errors" {
	assert hasError("const a: number = 5;\nconst b: number = 3;\nconst c = a ^ b;", "bitwise operator '^' requires integer type");
}

test "number >>> number errors" {
	assert hasError("const a: number = 8;\nconst b: number = 2;\nconst c = a >>> b;", "bitwise operator '>>>' requires integer type");
}

// ===== Invalid: mixed integer sizes =====

test "int32 & int64 errors (mixed size)" {
	assert hasError("const a: int32 = 1 as int32;\nconst b: int64 = 2 as int64;\nconst c = a & b;", "requires same integer size");
}

test "uint8 | uint32 errors (mixed size)" {
	assert hasError("const a: uint8 = 1 as uint8;\nconst b: uint32 = 2 as uint32;\nconst c = a | b;", "requires same integer size");
}

// ===== Invalid: bitwise NOT on non-integer =====

test "~number errors" {
	assert hasError("const a: number = 42;\nconst b = ~a;", "bitwise NOT '~' requires integer type");
}

// ===== Invalid: mixed number and integer =====

test "int32 & number errors" {
	assert hasError("const a: int32 = 1 as int32;\nconst b: number = 2;\nconst c = a & b;", "bitwise operator '&' requires integer type");
}

test "number & int32 errors" {
	assert hasError("const a: number = 1;\nconst b: int32 = 2 as int32;\nconst c = a & b;", "bitwise operator '&' requires integer type");
}

// ===== Invalid: string/boolean bitwise =====

test "string & string errors" {
	assert hasError("const a = \"hi\";\nconst b = \"lo\";\nconst c = a & b;", "bitwise operator '&' requires integer type");
}

test "boolean | boolean errors" {
	assert hasError("const a = true;\nconst b = false;\nconst c = a | b;", "bitwise operator '|' requires integer type");
}

// ===== Error count validation =====

test "number & number produces 2 errors (one per operand)" {
	const src = "const a: number = 1;\nconst b: number = 2;\nconst c = a & b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	let bitwiseErrors = 0;
	let i = 0;
	while (i < ctx.errors.length) {
		if (ctx.errors[i].message.indexOf("bitwise") >= 0) bitwiseErrors = bitwiseErrors + 1;
		i = i + 1;
	}
	assert bitwiseErrors === 2;
}

test "int32 & int64 produces 1 error (size mismatch)" {
	const src = "const a: int32 = 1 as int32;\nconst b: int64 = 2 as int64;\nconst c = a & b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	let sizeErrors = 0;
	let i = 0;
	while (i < ctx.errors.length) {
		if (ctx.errors[i].message.indexOf("same integer size") >= 0) sizeErrors = sizeErrors + 1;
		i = i + 1;
	}
	assert sizeErrors === 1;
}

// ===== Non-bitwise ops still work on number =====

test "number + number is valid" {
	assert errorCount("const a: number = 1;\nconst b: number = 2;\nconst c = a + b;") === 0;
}

test "number * number is valid" {
	assert errorCount("const a: number = 3;\nconst b: number = 4;\nconst c = a * b;") === 0;
}

test "number === number is valid" {
	assert errorCount("const a: number = 1;\nconst b: number = 2;\nconst c = a === b;") === 0;
}
