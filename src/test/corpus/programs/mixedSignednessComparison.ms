// Parity program — a comparison between a signed and an unsigned integer compiles only when one type
// holds every value of the other, and then compares the values on every backend; the rest needs `as`.
//
// @stdout: true true false true | true false true | true true false

const wide: int64 = -1;
const big: uint32 = 3000000000 as uint32;
const byte: uint8 = 200;
const small: int16 = -1;
const li: int32 = -1;
const count: uint64 = 3 as uint64;
console.log(`${wide < big} ${byte > small} ${big === wide} ${byte >= li} | ${count > 0} ${count < 0} ${(li as uint64) > count} | ${(count as int32) > li} ${(big as int64) > wide} ${big == (li as uint32)}`);
