// Parity program — a uint64 past int64 compares, divides, takes a remainder,
// prints and converts as unsigned on every backend.
//
// @stdout: true true false true 9223372036854775807 5 15 18446744073709551615 18446744073709551615 18446744073709552000 18446744073709552000 -1 u=18446744073709551615 6148914691236517205 1 9223372036854775808
// @exit: 0

function big(): uint64 { return 18446744073709551615; }
function one(): uint64 { return 1; }
function half(v: number): uint64 { return v as uint64; }

const a = big();
const b = one();
let s = "u=";
s += a;
let q = a;
q /= 3;
let m = a;
m %= 7;
console.log(b < a, a > b, a <= b, a >= b, a / 2, a % 10, a >> 60, `${a}`, a.toString(), a as number, a as float32, a as int64, s, q, m, half(9223372036854775808.0));
