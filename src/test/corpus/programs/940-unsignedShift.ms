// @xfail(raiser): the Raiser bytecode compiler has no `>>>` (cannot evaluate operator at comptime)
// @stdout: 2147483644 4 9223372036854775804 25 2147483644
// note: `>>>` shifts the operand's own width as unsigned and masks the count to that width (codegen-c-8: C had no lowering and failed the build).

function s32(a: int32, n: int32): int32 { return a >>> n; }
function u32(a: uint32, n: uint32): uint32 { return a >>> n; }
function s64(a: int64, n: int64): int64 { return a >>> n; }
function u8(a: uint8, n: uint8): uint8 { return a >>> n; }

const a = s32(-8, 1);
const b = u32(8, 1);
const c = s64(-8 as int64, 1 as int64);
const d = u8(200 as uint8, 3 as uint8);
const e = s32(-8, 33);
console.log(`${a} ${b} ${c} ${d} ${e}`);
