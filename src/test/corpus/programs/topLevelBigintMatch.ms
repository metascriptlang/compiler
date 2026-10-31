// @stdout: 5
// @xfail(raiser): bigint is not supported on the Raiser VM
// note: a top-level bigint binding set from a match keeps its owned slot through the arm assignment.

const n = "ab".length - 1;
const big: bigint = match (n) { 1 => 5n, _ => 6n };
console.log(big.toString());
