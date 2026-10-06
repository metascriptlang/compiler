// @exit: 1
// @stdout: start 3 -1 0 1
// @xfail(danger): --danger elides the division checks, so 7 / 0 is undefined there
// @xfail(raiser): the Raiser VM reports the uncaught division by zero as its own 'raiser runtime error' on stderr, not C's 'Error: division by zero'
// note: an integer division by zero raises on every backend in debug and release instead of printing a value (codegen-c-9: C --release and JS printed 0 and went on). The remainder of MIN by -1 is 0 and does not raise.

function d(a: int32, b: int32): int32 { return a / b; }
function m(a: int32, b: int32): int32 { return a % b; }

const lo: int32 = -2147483647 - 1;
console.log(`start ${d(7, 2)} ${m(-7, 2)} ${m(lo, -1)} ${d(1, 1)}`);
console.log(d(7, 0));
console.log("after");
