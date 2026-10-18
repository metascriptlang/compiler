// @exit: 1
// @stdout: The number 1.5 cannot be converted to a BigInt because it is not an integer
// @xfail(raiser): bigint is not supported on the Raiser VM
// @xfail(js): node reports the uncaught error with its own trace on stderr, where C prints 'Error: unhandled exception: ' and the message
// @xfail(esm): node reports the uncaught error with its own trace on stderr, where C prints 'Error: unhandled exception: ' and the message
// note: an uncaught RangeError from `as bigint` on a number that is not an integer ends the program with exit 1 and node's message on C and JS; C used to abort with exit 134.

function f64(v: float64): float64 { return v; }

console.log("before");
const b = f64(1.5) as bigint;
console.log(`unreachable ${b}`);
