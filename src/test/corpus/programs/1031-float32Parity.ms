// Parity program — float32 and double arithmetic give the same bits on every
// backend: JS rounds each float32 result, C never fuses a*b+c into one rounding.
//
// @stdout: 0.10000000149011612 1 16777216 16777216 0.10000000149011612 1152921642045800400 18446744073709552000 16777216 0 0
// @exit: 0

function fma(a: number, b: number, c: number): number { return a * b + c; }
function fma32(a: float32, b: float32, c: float32): float32 { return a * b + c; }
function chain(v: number): number { return (v as float32) as number; }

const a: float32 = 0.1;
let b: float32 = a * 3;
b += 0.7;
let c: float32 = 16777216;
c++;
const old = c++;
const big: int64 = 1152921573326323713;
const ub: uint64 = 18446744073709551615;
let i32: int32 = 16777217;
const p: float32 = 0.1;
const q: float32 = 10;
const r: float32 = -1;
console.log(a, b, c, old, chain(0.1), big as float32, ub as float32, i32 as float32, fma(0.1, 10, -1), fma32(p, q, r));
