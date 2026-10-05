// @xfail(raiser): the Raiser bytecode compiler has no `>>>` (cannot evaluate operator at comptime)
// @stdout: 2147483644 4 9223372036854775804 25 2147483644 -1 assign 2147483644 4 9223372036854775804 25 2147483644 127 -1 calls=2 number -1,-1 2147483644,2147483644 15
// note: `>>>` shifts the operand's own width as unsigned and masks the count to that width (codegen-c-8: C had no lowering and failed the build). `x >>>= n` stores the same value and reads x once; a signed result stays in its type when the count is a multiple of the width. A `number` target takes `>>>=` as `x = x >>> n`, an int32 result.

function s32(a: int32, n: int32): int32 { return a >>> n; }
function u32(a: uint32, n: uint32): uint32 { return a >>> n; }
function s64(a: int64, n: int64): int64 { return a >>> n; }
function u8(a: uint8, n: uint8): uint8 { return a >>> n; }

const a = s32(-8, 1);
const b = u32(8, 1);
const c = s64(-8 as int64, 1 as int64);
const d = u8(200 as uint8, 3 as uint8);
const e = s32(-8, 33);

function s32Assign(a: int32, n: int32): int32 { a >>>= n; return a; }
function u32Assign(a: uint32, n: uint32): uint32 { a >>>= n; return a; }
function s64Assign(a: int64, n: int64): int64 { a >>>= n; return a; }
function u8Assign(a: uint8, n: uint8): uint8 { a >>>= n; return a; }
let calls: int32 = 0;
function first(): int32 { calls += 1; return 0; }
const bytes: int8[] = [-1];
bytes[first()] >>>= 1;
const words: int32[] = [-1];
const zero: int32 = 0;
words[zero] >>>= 32;
function numAssign(a: number, n: int32): number { a >>>= n; return a; }
function numBinary(a: number, n: int32): number { return a >>> n; }
const nums: number[] = [-1];
nums[first()] >>>= 28;
const assigned = `${s32Assign(-8, 1)} ${u32Assign(8, 1)} ${s64Assign(-8 as int64, 1 as int64)} ${u8Assign(200 as uint8, 3 as uint8)} ${s32Assign(-8, 33)}`;
console.log(`${a} ${b} ${c} ${d} ${e} ${s32(-1, 32)} assign ${assigned} ${bytes[0]} ${words[0]} calls=${calls} number ${numAssign(-1, 0)},${numBinary(-1, 0)} ${numAssign(-8, 1)},${numBinary(-8, 1)} ${nums[0]}`);
