// @stdout: 5 -7 5
// @stdout: x 5 -7
// @stdout: 9007199254740993 -9007199254740993
let a: uint64 = 5;
let b: int64 = -7;
function widen(v: int64 | string): int64 | string | boolean { return v; }
const a2: int64 | string = 41;
const big: int64 = 9007199254740993;
const nbig: int64 = -9007199254740993;
console.log(a, b, `${a}`);
console.log("x", a, b);
console.log(widen(a2));
console.log(big, nbig);
