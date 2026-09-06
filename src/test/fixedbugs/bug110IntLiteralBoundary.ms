// bug110 — an integer literal at the 64-bit boundary aborted the compiler
//
// Symptom:    `const v: int64 = -9223372036854775808;` killed msc during PARSE
//             with "signed integer overflow: 9223372036854775800 + 8", before
//             any diagnostic could exist. The target type was irrelevant —
//             `int32 = 9223372036854775808` and `number = 9223372036854775808`
//             died the same way, and so did a plain typo like
//             `99999999999999999999`. Radix did not matter either:
//             `0x8000000000000000` died on `576460752303423488 * 16`.
// Root cause: parseIntegerLiteral accumulated the magnitude in a SIGNED int64
//             (`result = result * radix + digit`) with no overflow check, so
//             every literal whose magnitude reaches 2^63 trapped. Nim never
//             accumulates signed: base-10 unsigned goes through
//             parseBiggestUInt + cast[int64] (lexer.nim:519-527) and the
//             bit-pattern radices accumulate into `xi` (lexer.nim:480-491).
// Fix:        accumulate unsigned, bound-check BEFORE the multiply, apply the
//             sign at the end, return the bit pattern. Anything past 2^64-1 is
//             reported as Nim reports it — "number out of range: '<literal>'".
//
// Values here live inside SOURCE STRINGS on purpose: the guard file must stay
// compilable by the very generation that cannot yet parse these literals.
// Runtime fidelity of the parsed values is corpus 013-int64Fidelity's job;
// this pins the compile-time contract that used to be an abort.

import { hasError, strictErrorCount } from "../handoff/helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

test "bug110: decimal int64 min is accepted" {
	assert accepts("function f(): int64 { const v: int64 = -9223372036854775808; return v; }");
}

test "bug110: decimal int64 max is accepted" {
	assert accepts("function f(): int64 { const v: int64 = 9223372036854775807; return v; }");
}

test "bug110: digit separators do not change the boundary" {
	assert accepts("function f(): int64 { const v: int64 = 9_223_372_036_854_775_807; return v; }");
	assert hasError("function f(): int64 { const v: int64 = 99_999_999_999_999_999_999; return v; }", "number out of range");
}

test "bug110: bit-pattern radices span the unsigned width" {
	assert accepts("function f(): int64 { const v: int64 = 0x8000000000000000; return v; }");
	assert accepts("function f(): int64 { const v: int64 = 0xFFFFFFFFFFFFFFFF; return v; }");
	assert accepts("function f(): int64 { const v: int64 = 0b1000000000000000000000000000000000000000000000000000000000000000; return v; }");
}

test "bug110: unsigned decimal reaches uint64 max" {
	assert accepts("function f(): uint64 { const v: uint64 = 18446744073709551615; return v; }");
}

test "bug110: past the 64-bit envelope is a diagnostic, not an abort" {
	assert hasError("function f(): int64 { const v: int64 = 99999999999999999999; return v; }", "number out of range");
	assert hasError("function f(): int64 { const v: int64 = 18446744073709551616; return v; }", "number out of range");
	assert hasError("function f(): int64 { const v: int64 = 0x1FFFFFFFFFFFFFFFF; return v; }", "number out of range");
}

test "bug110: the out-of-range diagnostic quotes the literal" {
	assert hasError("function f(): int64 { const v: int64 = 99999999999999999999; return v; }", "'99999999999999999999'");
}

test "bug110: a too-wide literal in a narrow type is a type error, not an abort" {
	assert strictErrorCount("function f(): int32 { const v: int32 = 9223372036854775808; return v; }") > 0;
}

// The minus sign sits in a UnaryExpr, not in the token, so before the fix the
// range rule only ever saw a magnitude — which made every signed MIN illegal
// and let every positive overflow through. Both directions are pinned here.

test "bug110: every signed MIN is writable" {
	assert accepts("function f(): int8 { const v: int8 = -128; return v; }");
	assert accepts("function f(): int16 { const v: int16 = -32768; return v; }");
	assert accepts("function f(): int32 { const v: int32 = -2147483648; return v; }");
}

test "bug110: one past each signed MIN is rejected" {
	assert hasError("function f(): int8 { const v: int8 = -129; return v; }", "cannot convert");
	assert hasError("function f(): int16 { const v: int16 = -32769; return v; }", "cannot convert");
	assert hasError("function f(): int32 { const v: int32 = -2147483649; return v; }", "cannot convert");
}

test "bug110: the positive side of each signed MAX still binds" {
	assert accepts("function f(): int8 { const v: int8 = 127; return v; }");
	assert hasError("function f(): int8 { const v: int8 = 128; return v; }", "cannot convert");
	assert hasError("function f(): int32 { const v: int32 = 2147483648; return v; }", "cannot convert");
}

test "bug110: a bit pattern may fill the unsigned width of a signed target" {
	assert accepts("function f(): int8 { const v: int8 = 0x80; return v; }");
	assert accepts("function f(): int8 { const v: int8 = 0xFF; return v; }");
	assert hasError("function f(): int8 { const v: int8 = 0x100; return v; }", "cannot convert");
	assert accepts("function f(): int32 { const v: int32 = 0xFFFFFFFF; return v; }");
}

test "bug110: int64 magnitude 2^63 is legal only with the minus" {
	assert accepts("function f(): int64 { const v: int64 = -9223372036854775808; return v; }");
	assert hasError("function f(): int64 { const v: int64 = 9223372036854775808; return v; }", "cannot convert");
	assert hasError("function f(): int64 { const v: int64 = -9223372036854775809; return v; }", "cannot convert");
	assert hasError("function f(): int64 { const v: int64 = 9223372036854775809; return v; }", "cannot convert");
}

test "bug110: a minus in front of an unsigned target is rejected" {
	assert hasError("function f(): uint64 { const v: uint64 = -1; return v; }", "cannot convert");
	assert hasError("function f(): uint8 { const v: uint8 = -1; return v; }", "cannot convert");
	assert accepts("function f(): uint64 { const v: uint64 = 18446744073709551615; return v; }");
}
