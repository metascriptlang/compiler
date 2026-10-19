// @exit: 1
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the power wraps in C instead of stopping
// @skip-raiser: the raiser stops too, with a range error on stderr, which the raiser lane does not read; run it with msc run --target=raiser
// note: `**=` on an int8 element stops when the power leaves int8, where it wrapped to 0 on C before.

function int8Of(n: int32): int8 { return n as int8; }

const xs: int8[] = [int8Of(1), int8Of(16)];
xs[1] **= int8Of(2);
console.log(`unreachable ${xs[1]}`);
