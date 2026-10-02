// @xfail(raiser): the Raiser bytecode compiler has no `>>>` (cannot evaluate operator at comptime)
// @stdout: 2147483647 2147483647 100 20000 2147483646 2147483646 100 20000
// note: `>>>` on an 8/16-bit integer converted to uint32 shifts the uint32 value, signed sources included.

let s8: int8 = -1;
let s16: int16 = -2;
let u8: uint8 = 200;
let u16: uint16 = 40000;
const a8: int8[] = [-3];
const a16: int16[] = [-4];
const b8: uint8[] = [201];
const b16: uint16[] = [40001];

console.log(`${(s8 as uint32) >>> 1} ${(s16 as uint32) >>> 1} ${(u8 as uint32) >>> 1} ${(u16 as uint32) >>> 1} ${(a8[0] as uint32) >>> 1} ${(a16[0] as uint32) >>> 1} ${(b8[0] as uint32) >>> 1} ${(b16[0] as uint32) >>> 1}`);
