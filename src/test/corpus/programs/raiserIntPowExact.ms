// @stdout: -1 1 -1 1
// @stdout: 0 1 0 1
// @stdout: 4052555153018976267 -9223372036854775808 1 9223372036854775808
// @stdout: 1162261467 -1 0 243
// note: an integer `**` multiplies by squaring on every backend, so a unit or zero base keeps its sign and value at an
// exponent past 2^53, where a double exponent rounds to an even number; the same operands go through `**=`.

function i64(n: int64): int64 { return n; }
function i32(n: int32): int32 { return n; }
function u64(n: uint64): uint64 { return n; }
function u8(n: uint32): uint8 { return n as uint8; }

const huge = i64(9223372036854775807);
console.log(`${i64(-1) ** huge} ${i64(-1) ** (huge - 1)} ${i32(-1) ** i32(2147483647)} ${i32(-1) ** i32(2147483646)}`);
console.log(`${i64(0) ** huge} ${i64(1) ** huge} ${u64(0) ** u64(18446744073709551615)} ${u64(1) ** u64(18446744073709551615)}`);
console.log(`${i64(3) ** i64(39)} ${i64(-2) ** i64(63)} ${i64(2) ** i64(0)} ${u64(2) ** u64(63)}`);

let a = i32(3);
a **= i32(19);
let b = i64(-1);
b **= huge;
let c = u64(0);
c **= u64(18446744073709551615);
console.log(`${a} ${b} ${c} ${u8(3) ** u8(5)}`);
