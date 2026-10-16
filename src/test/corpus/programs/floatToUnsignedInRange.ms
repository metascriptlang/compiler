// note: a float converted to an unsigned type inside its range truncates toward zero, from float64, float32, number and a generic `as T`, the same on C, JS and the Raiser.

function toU8(v: float64): uint8 { return v as uint8; }
function toU16(v: float64): uint16 { return v as uint16; }
function toU32(v: float64): uint32 { return v as uint32; }
function toU64(v: float64): uint64 { return v as uint64; }
function f32ToU8(v: float32): uint8 { return v as uint8; }
function f32ToU64(v: float32): uint64 { return v as uint64; }
function numToU32(v: number): uint32 { return v as uint32; }
function conv<T>(v: float64): T { return v as T; }

const negZero: float64 = -0.0;
console.log(`u8 ${toU8(-0.9)} ${toU8(negZero)} ${toU8(0.5)} ${toU8(127.9)} ${toU8(255.9)}`);
console.log(`u16 ${toU16(-0.5)} ${toU16(32768.25)} ${toU16(65535.99)}`);
console.log(`u32 ${toU32(2147483648.0)} ${toU32(4294967295.5)} ${numToU32(4294967294.9)}`);
console.log(`u64 ${toU64(-0.75)} ${toU64(9007199254740993.0)} ${toU64(9223372036854775808.0)} ${toU64(1e19)} ${toU64(18446744073709549568.0)}`);
console.log(`f32 ${f32ToU8(255.5)} ${f32ToU8(-0.5)} ${f32ToU64(16777217.0)} ${f32ToU64(18446742974197923840.0)}`);
console.log(`generic ${conv<uint8>(200.5)} ${conv<uint32>(3000000000.5)} ${conv<uint64>(4294967296.5)}`);
