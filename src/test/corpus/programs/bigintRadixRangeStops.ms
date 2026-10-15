// @exit: 1
// @stdout: toString() radix argument must be between 2 and 36
// @xfail(raiser): bigint is not supported on the Raiser VM
// @xfail(js): node reports the uncaught error with its own trace on stderr, where C prints 'Error: unhandled exception: ' and the message
// @xfail(esm): node reports the uncaught error with its own trace on stderr, where C prints 'Error: unhandled exception: ' and the message
// note: an uncaught RangeError from a bigint toString with a radix outside 2..36 ends the program with exit 1 and node's message on C and JS; C used to abort with exit 134.

function radixOf(n: int32): int32 { return n; }

const big: bigint = 255n;
console.log("before");
console.log(big.toString(radixOf(37)));
