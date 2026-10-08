// Parity program — a negation whose operand is spelled as a negative literal
// builds on C: the operand is parenthesized, so `-` before `-128` is not `--`.
// The 8- and 16-bit minimum negates to itself, as `0 - MIN` does at that width.
//
// @stdout: -128 -32768 -128 127 7 -32768
// @exit: 0

const a: int8 = (-((-128) as int8));
const b: int16 = (-((-32768) as int16));
const m: int8 = (-128) as int8;
const e: int8 = (~((-128) as int8));
const f: int16 = (-(-(7 as int16)));
const z: int16 = 0;
const n: int16 = (-32768) as int16;
console.log(a, b, -m, e, f, z - n);
