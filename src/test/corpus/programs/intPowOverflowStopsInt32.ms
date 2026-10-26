// @exit: 1
// @stdout: kept 1162261467
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the power wraps in C instead of stopping
// @skip-raiser: the raiser computes an integer power in doubles and stops with its own range error on stderr, which the raiser lane does not read
// note: an int32 power that fits is kept and one past the type's bound stops with the overflow message on C and JS, as the checked multiply it is built from does.

function pow(a: int32, b: int32): int32 { return a ** b; }

console.log(`kept ${pow(3, 19)}`);
console.log(`unreachable ${pow(3, 21)}`);
