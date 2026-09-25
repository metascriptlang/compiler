// @stdout: 2 -2147483648 -2147483648 -4 4294967295 2 -9223372036854775808 -4
// note: a shift count is masked to the operand width on every backend, so a count at or past the width is defined (stmt-lowering-18, codegen-c-5: C shifted by the raw count).

function shl32(a: int32, n: int32): int32 { return a << n; }
function shr32(a: int32, n: int32): int32 { return a >> n; }
function shrU32(a: uint32, n: uint32): uint32 { return a >> n; }
function shl64(a: int64, n: int64): int64 { return a << n; }
function shr64(a: int64, n: int64): int64 { return a >> n; }

const row32 = `${shl32(1, 33)} ${shl32(1, 31)} ${shl32(3, -1)} ${shr32(-8, 33)} ${shrU32(4294967295, 32)}`;
const row64 = `${shl64(1 as int64, 65 as int64)} ${shl64(1 as int64, 63 as int64)} ${shr64(-8 as int64, 65 as int64)}`;
console.log(`${row32} ${row64}`);
