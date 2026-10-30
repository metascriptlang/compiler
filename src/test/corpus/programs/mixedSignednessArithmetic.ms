// Parity program — + - * / % between a signed and an unsigned integer compiles only when one type
// holds every value of the other, and then computes the values on every backend; the rest needs `as`.
//
// @stdout: -1 -2 1431655763 2 | -1 -2 83 2 | -1 -2 -2 -15 199

const a: int32 = -5;
const b: uint32 = 3;
const c: int8 = -5;
const d: uint8 = 3;
const byte: uint8 = 200;
const li: int32 = -1;
console.log(`${a / (b as int32)} ${a % (b as int32)} ${(a as uint32) / b} ${(a as uint32) % b} | ${c / (d as int8)} ${c % (d as int8)} ${(c as uint8) / d} ${(c as uint8) % d} | ${a / d} ${a % d} ${a + d} ${d * a} ${byte + li}`);
