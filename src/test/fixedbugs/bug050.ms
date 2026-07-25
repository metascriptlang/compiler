// bug050 — number→string printed 17 digits, and large values trapped
//
// Symptom:    `${3.14}` produced "3.1400000000000001" and `${0.1}` produced
//             "0.10000000000000001", so every float that reached a template
//             literal, string concat or .toString() was unreadable. Separately,
//             `${1e21}` aborted the program:
//             "1000000000000000000000 is outside the range of representable
//             values of type 'long long'".
//
// Root cause: runtime/core/string.c msNumberToString did two things wrong.
//             (1) It formatted with "%.17g" — the widest round-tripping form —
//             instead of the SHORTEST round-tripping form, so it always spelled
//             out the binary noise. (2) Its integer fast path read
//             `value == (double)(int64_t)value && value >= -1e15 && ...`, which
//             performs the out-of-range int64 cast BEFORE the guard that was
//             meant to prevent it — undefined behaviour for any |value| beyond
//             int64 range, trapped by the sanitizer in debug builds.
//
// Fix:        rewrote msNumberToString: guard first then cast, and emit the
//             ECMA-262 Number::toString(x, 10) form — shortest round-tripping
//             digits (smallest precision whose "%.*e" re-parses to the same
//             double), then fixed vs exponential chosen by the decimal exponent
//             (fixed while -6 < n <= 21), with an unpadded exponent.
//
// Verified:   the shipped function was differential-tested against the JS
//             reference over 3,000,015 doubles (random bit patterns, decimal
//             literals, ratios, plus the spec edge cases) with zero mismatches.

test "bug050: floats print their shortest round-trip form" {
    assert `${3.14}` === "3.14";
    assert `${0.1}` === "0.1";
    assert `${-3.14}` === "-3.14";
    assert `${1.0 / 3.0}` === "0.3333333333333333";
}

test "bug050: integral doubles print without a fraction" {
    assert `${100.0}` === "100";
    assert `${0.0}` === "0";
}

test "bug050: large magnitudes format instead of trapping" {
    assert `${1e21}` === "1e+21";
    assert `${1e20}` === "100000000000000000000";
}

test "bug050: the exponential threshold follows the spec, unpadded" {
    assert `${0.000001}` === "0.000001";
    assert `${1e-7}` === "1e-7";
}
