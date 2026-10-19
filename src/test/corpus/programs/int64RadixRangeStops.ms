// @exit: 1
// @stdout: toString() radix argument must be between 2 and 36
// @skip-raiser: the raiser throws the same message as an unhandled exception on stderr, which the raiser lane does not read; numberToStringRadix pins the raiser digits
// @xfail(js): node reports the uncaught error with its own trace on stderr, where C prints 'Error: unhandled exception: ' and the message
// @xfail(esm): node reports the uncaught error with its own trace on stderr, where C prints 'Error: unhandled exception: ' and the message
// note: an int64 toString with a radix outside 2..36 throws a RangeError that, uncaught, ends the program with exit 1 and node's message, as TS does.

function radixOf(n: int32): int32 { return n; }

const v: int64 = 255;
console.log(v.toString(radixOf(1)));
