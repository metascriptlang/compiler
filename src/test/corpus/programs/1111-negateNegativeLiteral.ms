// Parity program — a negation whose operand is spelled as a negative literal
// builds on C: the operand is parenthesized, so `-` before `-127` is not `--`.
// The 8- and 16-bit minimum is reached, not negated: negating it stops (signedOverflowStops*).
//
// @stdout: 127 32767 127 127 7 -32767
// @exit: 0

const a: int8 = (-((-127) as int8));
const b: int16 = (-((-32767) as int16));
const m: int8 = (-128) as int8;
const e: int8 = (~((-128) as int8));
const f: int16 = (-(-(7 as int16)));
const z: int16 = -1;
const n: int16 = (-32768) as int16;
console.log(a, b, -(m + 1), e, f, n - z);
