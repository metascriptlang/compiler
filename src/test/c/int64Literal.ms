// int64 literal fidelity — source text → emitted C.
//
// The AST stores every number literal as a double (`NumberLiteralData.value`,
// std/meta/node.ms), so a literal above 2^53 is truncated in the FRONT END,
// before any backend sees it — both backends inherit the loss. These tests pin
// the emitted digits, which is the only place the truncation is visible without
// running the program.
//
// Siblings: src/test/js/int64Literal.ms (same contract, JS backend) and
// corpus/programs/013-int64Fidelity.ms (runtime behaviour, C lanes).

import { compileToC } from "../helpers";

// ===== Literal digits reach the emitted C =====

test "int64 literal above 2^53 keeps its digits in C" {
	const result = compileToC("const a: int64 = 9007199254740993;");
	assert result.ok;
	assert result.value.contains("9007199254740993");
}

test "int64 literal at int64 max keeps its digits in C" {
	const result = compileToC("const a: int64 = 9223372036854775807;");
	assert result.ok;
	assert result.value.contains("9223372036854775807");
}

test "negative int64 literal below -2^53 keeps its digits in C" {
	const result = compileToC("const a: int64 = -9007199254740993;");
	assert result.ok;
	assert result.value.contains("9007199254740993");
}

// ===== int64 → string must not go through the double formatter =====
// msNumberToString takes a `double` (runtime/core/string.h), so routing an
// int64 through it truncates at 2^53 no matter how exact the value is.

test "int64 concat uses the integer formatter, not msNumberToString" {
	const result = compileToC("const a: int64 = 42;\nconst s = \"v=\" + a;");
	assert result.ok;
	assert result.value.contains("msIntToString");
}

test "int64 toString() uses the integer formatter, not msNumberToString" {
	const result = compileToC("const a: int64 = 42;\nconst s = a.toString();");
	assert result.ok;
	assert result.value.contains("msIntToString");
}

test "float64 keeps using msNumberToString" {
	const result = compileToC("const a: float64 = 4.5;\nconst s = a.toString();");
	assert result.ok;
	assert result.value.contains("msNumberToString");
}

// ===== bigint literal: a distinct primitive, no longer an int64 spelling =====
// `123n` is typed `bigint` (arbitrary precision). It does not flow into int64
// slots, and a literal beyond int64 is legal — the checker no longer bounds it.

test "bigint literal does not fit an int64 slot" {
	const result = compileToC("function f(): int64 { return 123n; }");
	assert !result.ok;
}

test "int64 does not fit a bigint slot without an explicit conversion" {
	const result = compileToC("function k(x: bigint): void { }\nconst a: int64 = 5;\nk(a);");
	assert !result.ok;
}

test "bigint literal beyond int64 typechecks" {
	const result = compileToC("const a: bigint = 123456789012345678901234567890n;");
	assert result.ok;
}
