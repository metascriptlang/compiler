// @exit: 1
// @stdout: kept 1 1
// @stdout: value -1 not in range 0 .. 2147483647
// @xfail(danger): --danger drops the exponent check on C, so a negative exponent truncates to 0 instead of stopping
// @skip-raiser: the raiser stops with its own message on stderr, which the raiser lane does not read
// note: a negative int32 exponent stops with the range error of the exponent, as the reference's natural-number exponent does; 0 and a positive exponent run.

function pow(a: int32, b: int32): int32 { return a ** b; }

console.log(`kept ${pow(5, 0)} ${pow(1, 1)}`);
console.log(`unreachable ${pow(2, -1)}`);
