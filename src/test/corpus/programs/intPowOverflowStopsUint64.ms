// @exit: 1
// @stdout: kept 12157665459056928801
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the power wraps in C instead of stopping
// @skip-raiser: the raiser computes an integer power in doubles and stops with its own range error on stderr, which the raiser lane does not read
// note: a uint64 power that fits is kept and one past the type's bound stops with the overflow message on C and JS.

function pow(a: uint64, b: uint64): uint64 { return a ** b; }

console.log(`kept ${pow(3, 40)}`);
console.log(`unreachable ${pow(3, 41)}`);
