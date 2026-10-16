// @exit: 1
// @stdout: toString() radix argument must be between 2 and 36
// @skip-raiser: the raiser throws the same message as an unhandled exception on stderr, which the raiser lane does not read; numberToStringRadix pins the raiser digits
// note: an int64 toString with a radix outside 2..36 stops the program, as TS does with a RangeError.

function radixOf(n: int32): int32 { return n; }

const v: int64 = 255;
console.log(v.toString(radixOf(1)));
