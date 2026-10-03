// @stdout: 4294967295 4294967294 200 40000 4294967293 4294967292 201 40001
// note: an 8/16-bit integer converted to uint32 keeps the uint32 value and width for every operator applied to it, signed sources included.

let s8: int8 = -1;
let s16: int16 = -2;
let u8: uint8 = 200;
let u16: uint16 = 40000;
const a8: int8[] = [-3];
const a16: int16[] = [-4];
const b8: uint8[] = [201];
const b16: uint16[] = [40001];
let n: uint32 = 4;

console.log(`${s8 as uint32} ${s16 as uint32} ${u8 as uint32} ${u16 as uint32} ${a8[0] as uint32} ${a16[0] as uint32} ${b8[0] as uint32} ${b16[0] as uint32}`);
console.log(`${(s8 as uint32) << 8} ${(s16 as uint32) << n} ${(u8 as uint32) << 8} ${(u16 as uint32) << 8} ${(a8[0] as uint32) << 8} ${(a16[0] as uint32) << n} ${(b8[0] as uint32) << 8} ${(b16[0] as uint32) << 8}`);
console.log(`${(s8 as uint32) >> 28} ${(s16 as uint32) >> n} ${(u8 as uint32) >> 3} ${(u16 as uint32) >> 3} ${(a8[0] as uint32) >> 28} ${(a16[0] as uint32) >> n} ${(b8[0] as uint32) >> 3} ${(b16[0] as uint32) >> 3}`);
console.log(`${(s8 as uint32) > 100} ${(s16 as uint32) > 100} ${(u8 as uint32) > 100} ${(u16 as uint32) > 100} ${(a8[0] as uint32) > 100} ${(a16[0] as uint32) > 100} ${(b8[0] as uint32) > 100} ${(b16[0] as uint32) > 100}`);
