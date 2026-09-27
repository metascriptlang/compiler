// bug498 — a float converted to int64 was not range-checked, and the checks cast first
//
// Symptom:    `f as int64` for f = 1e19 or NaN printed garbage under --release (UBSan panic in
//             debug); `f as int32` for NaN panicked inside msCheckRangeI32 instead of raising the
//             range error.
// Root cause: rangeCheckInject had no int64 row, and every msCheckRange helper converted the
//             double to int64 before comparing, which is undefined for NaN and |v| >= 2^63.
// Fix:        a float to int64 conversion calls msCheckRangeI64, and the helpers compare the
//             double against the bounds before the cast (runtime/core/system.h).

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "bug498: a float to int64 conversion calls the int64 range check" {
	assert cOf("export function f(x: float64): int64 { return x as int64; }\n").contains("msCheckRangeI64(x)");
}

test "bug498: an int32 to int64 conversion needs no range check" {
	assert !cOf("export function f(x: int32): int64 { return x as int64; }\n").contains("msCheckRangeI64");
}

test "bug498: a float to int32 conversion keeps its range check" {
	assert cOf("export function f(x: float64): int32 { return x as int32; }\n").contains("msCheckRangeI32(x");
}
