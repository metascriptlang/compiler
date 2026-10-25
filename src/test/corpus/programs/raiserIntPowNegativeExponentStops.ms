// @exit: 1
// @stdout: kept 1
// @stdout: value -1 not in range 0 .. 9223372036854775807
// note: a negative integer exponent stops with a range error on every backend instead of rounding through a double.

function i64(n: int64): int64 { return n; }

console.log(`kept ${i64(1) ** i64(0)}`);
console.log(`${i64(-3) ** i64(-1)}`);
console.log("unreachable");
