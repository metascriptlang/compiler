// @stdout: true true true
// @stdout: true true false
// @stdout: true true false
// @stdout: true true false
function zero(): int64 | null { return 0; }
function zeroU(): uint64 | null { return 0; }
function neg(): int64 | null { return -5; }
const plain: int64 = 0;
console.log(zero() == 0, zero() == plain, plain == 0);
console.log(zero() == (0 as int64), zero() === 0, zero() != 0);
console.log(0 == zeroU(), zeroU() == 0, 0 != zeroU());
console.log(neg() == -5, -5 == neg(), neg() == 5);
