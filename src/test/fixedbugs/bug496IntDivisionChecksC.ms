// bug496 — integer division, remainder and power produced a value where they must raise
//
// Symptom:    `7 / 0` printed 0 under --release and on JS, INT_MIN / -1 printed 0 (C) or
//             2147483648 (JS), and an integer `**` went through the double pow: 3 ** 39 lost
//             its low digits and an overflow was a float-to-int cast (UBSan panic in debug).
// Root cause: C codegen emitted the bare `/`, `%` and `(T)pow(a, b)`; JS emitted `(a / b) | 0`,
//             `a % b` and `a ** b`. Nothing inserted the zero divisor, MIN / -1 or overflow checks.
// Fix:        a native transform (intCheckInject) turns `/`, `%`, `/=`, `%=` into msDiv/msMod
//             calls unless the divisor is a literal other than 0 and -1 or the build is --danger,
//             and every integer `**` into msPow (msPowWrap under --danger); the JS integer pass
//             calls the same helpers, declared in the JS prelude.

import { compileToC, compileToJS } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function jsOf(source: string): string {
	const js = compileToJS(source);
	return js.ok ? js.value : js.error;
}

test "bug496: int32 division by a variable calls the checked division on C" {
	assert cOf("export function f(a: int32, b: int32): int32 { return a / b; }\n").contains("msDivI32(a, b)");
}

test "bug496: int32 division by a literal other than 0 and -1 stays an operator on C" {
	assert !cOf("export function f(a: int32): int32 { return a / 7; }\n").contains("msDivI32(");
}

test "bug496: int32 division by the literal -1 still checks MIN / -1 on C" {
	assert cOf("export function f(a: int32): int32 { return a / -1; }\n").contains("msDivI32(");
}

test "bug496: int64 remainder by a variable calls the checked remainder on C" {
	assert cOf("export function f(a: int64, b: int64): int64 { return a % b; }\n").contains("msModI64(a, b)");
}

test "bug496: uint16 division runs unsigned at 32 bits and converts back on C" {
	assert cOf("export function f(a: uint16, b: uint16): uint16 { return a / b; }\n").contains("((uint16_t)(msDivU32(a, b)))");
}

test "bug496: a compound division reads its left side once on C" {
	assert cOf("export function f(xs: int32[], b: int32): void { xs[0] /= b; }\n").contains("msDivAssignI32(");
}

test "bug496: an integer power calls the integer power on C" {
	const c = cOf("export function f(a: int64, b: int64): int64 { return a ** b; }\n");
	assert c.contains("msPowI64(a, b)");
	assert !c.contains("pow(a, b)");
}

test "bug496: int32 division by a variable calls the checked division on JS" {
	assert jsOf("export function f(a: int32, b: int32): int32 { return a / b; }\n").contains("msDivI32");
}

test "bug496: an integer power calls the integer power on JS" {
	assert jsOf("export function f(a: int32, b: int32): int32 { return a ** b; }\n").contains("msPowI32");
}
