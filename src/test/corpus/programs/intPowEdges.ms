// @stdout: i32 1 1 1 -1 1 1024 -2147483648 0 0
// @stdout: i64 1 1 1 -1 1 1099511627776 -9223372036854775808 0 0
// @stdout: u32 1 1 1 1024 4294967295 0
// @stdout: u64 1 1 1 1099511627776 18446744073709551615 0
// @stdout: narrow 64 255 127 -128 16 9 81 6561
// @stdout: assign 81 -32 0 4 125 2 232
// @xfail(raiser): the Raiser computes an integer power in doubles: int64 (-1) ** 9223372036854775807 is 1 and a uint64 exponent past int64 is a range error
// note: integer `**` on int32, int64, uint32 and uint64 keeps the value at the edges: 0 ** 0 is 1, 1 ** huge is 1, (-1) ** odd is -1 and ** even is 1, a power that lands on a bound is kept; `**=` on an own-width int8, uint8 and an effectful element index gives the same results.

function p32(a: int32, b: int32): int32 { return a ** b; }
function p64(a: int64, b: int64): int64 { return a ** b; }
function u32(a: uint32, b: uint32): uint32 { return a ** b; }
function u64(a: uint64, b: uint64): uint64 { return a ** b; }
function i8(a: int8, b: int8): int8 { return a ** b; }
function u8(a: uint8, b: uint8): uint8 { return a ** b; }

console.log("i32", p32(0, 0), p32(1, 2147483647), p32(-1, 0), p32(-1, 2147483647), p32(-1, 2147483646), p32(2, 10), p32(-2, 31), p32(0, 5), p32(0, 2147483647));
console.log("i64", p64(0, 0), p64(1, 9223372036854775807), p64(-1, 0), p64(-1, 9223372036854775807), p64(-1, 9223372036854775806), p64(2, 40), p64(-2, 63), p64(0, 5), p64(0, 9223372036854775807));
console.log("u32", u32(0, 0), u32(1, 4294967295), u32(7, 0), u32(2, 10), u32(4294967295, 1), u32(0, 4294967295));
console.log("u64", u64(0, 0), u64(1, 18446744073709551615), u64(7, 0), u64(2, 40), u64(18446744073709551615, 1), u64(0, 18446744073709551615));
console.log("narrow", i8(2, 6), u8(255, 1), i8(127, 1), i8(-2, 7), u8(2, 4), i8(3, 2), i8(-3, 4), p32(3, 8));

let x: int32 = 3;
x **= 4;
let n: int8 = -2;
n **= 5;
let m: uint8 = 2;
m **= 10 as uint8;
const xs: int32[] = [4, 5];
let k = 0;
function next(): int32 { k += 1; return k - 1; }
xs[next()] **= 1;
xs[next()] **= 3;
let big: uint8 = 10;
big **= 3 as uint8;
console.log("assign", x, n, m, xs[0], xs[1], k, big);
