// @exit: 1
// @stdout: kept 1
// @stdout: value -1 not in range 0 .. 9223372036854775807
// @xfail(danger): --danger drops range checks, so the power wraps instead of stopping
// @skip-raiser: the raiser stops with the same error but writes it to stderr, which the raiser lane does not read; src/codegen/raiser/eval.ms engine tests pin the raiser stop
// note: a negative integer exponent stops with a range error on every backend instead of rounding through a double.

function i64(n: int64): int64 { return n; }

console.log(`kept ${i64(1) ** i64(0)}`);
console.log(`${i64(-3) ** i64(-1)}`);
console.log("unreachable");
