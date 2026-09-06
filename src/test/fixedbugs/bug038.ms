// bug038 — float-typed integer-valued literals emit as C integer, breaking IEEE 754
//
// Symptom:    `const nan: number = 0.0 / 0.0;` panics at runtime with
//             "division by zero" instead of producing NaN. Same for
//             `1.0 / 0.0` (+Inf) and `-1.0 / 0.0` (-Inf). Trapped under
//             zig cc default UBSan integer-divide-by-zero check.
//
// Root cause: `formatCNumber(value)` in src/codegen/c/literals.ms inspected
//             only the runtime value, not the literal's type. Integer-valued
//             floats (0.0, 1.0, -1.0, 42.0) emitted as bare `0`/`1`/`42`,
//             so C parsed `0.0 / 0.0` as `(0 / 0)` — integer division by
//             zero, undefined behavior. Affected every float operation with
//             integer-valued operands, not just NaN/Inf: `2.0 / 3.0` would
//             have emitted as `2 / 3` = 0.
//
// Fix:        - formatCNumber now takes `(value, type)` and appends `.0`
//               when type is Number/Float32/Float64.
//             - 3 call sites updated (expressions.ms, declarations.ms x2).
//             - Switch case labels intercept NumberLiteral and force integer
//               emit (C requires integer constant expr in case labels;
//               checker may stamp Number on hex literals inconsistently).
//
// Reference: Nim emits float literals via toStrMaxPrecision (rodutils.nim:47)
//            which always preserves ".0" — Nim has separate nkFloatLit /
//            nkIntLit kinds so the literal kind itself disambiguates.

test "bug038: 0.0 / 0.0 produces NaN, not panic" {
	const nan: number = 0.0 / 0.0;
	assert nan != nan;  // NaN is the only value not equal to itself
}

test "bug038: 1.0 / 0.0 produces +Infinity" {
	const posInf: number = 1.0 / 0.0;
	assert posInf > 1e308;
}

test "bug038: -1.0 / 0.0 produces -Infinity" {
	const negInf: number = -1.0 / 0.0;
	assert negInf < -1e308;
}

test "bug038: float division with integer-valued operands preserves precision" {
	const quotient: number = 2.0 / 3.0;
	assert quotient > 0.66 && quotient < 0.67;
}
