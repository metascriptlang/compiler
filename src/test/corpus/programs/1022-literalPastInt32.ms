// Parity program — an integer literal past int32 keeps its value: it is int64,
// a literal-only expression folds exactly, and an overload picks the int64 form.
//
// @stdout: 5000000000 4000000001 10000000000 2147483648 -9223372036854775808 int64 int32
// @exit: 0

function width(v: int32): string { return "int32"; }
function width(v: int64): string { return "int64"; }

const big = 5000000000;
let grows = 4000000000;
grows = grows + 1;
const product = 100000 * 100000;
const edge = 2147483647 + 1;
const lowest = -9223372036854775808;
console.log(big, grows, product, edge, lowest, width(5000000000), width(5));
