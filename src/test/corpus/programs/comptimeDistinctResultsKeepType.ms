// @stdout: signed -128 -32768 -2147483648 -9223372036854775808 sizes 1 2 4 8 unsigned 255 4294967295 9223372036854775808 18446744073709551615 18446744073709551615 sizes 1 4 8 float 2.5 1.5 sizes 4 8 named a@b true
// note: a comptime result of a distinct type keeps that type at every base width, at the negative end and past 2^63, from a block and a @comptime function, as the same value computed at run time does.
type I8 = distinct int8;
type I16 = distinct int16;
type I32 = distinct int32;
type I64 = distinct int64;
type U8 = distinct uint8;
type U32 = distinct uint32;
type U64 = distinct uint64;
type F32 = distinct float32;
type F64 = distinct float64;
type Email = distinct string;
type Flag = distinct boolean;

@comptime function topLamports(): U64 { const v: uint64 = 18446744073709551615; return v as U64; }

const i8v = @comptime { const v: I8 = (-128) as I8; return v; };
const i16v = @comptime { const v: I16 = (-32768) as I16; return v; };
const i32v = @comptime { const v: I32 = (-2147483648) as I32; return v; };
const i64v = @comptime { const v: int64 = -9223372036854775807 - 1; return v as I64; };
const u8v = @comptime { const v: U8 = 255 as U8; return v; };
const u32v = @comptime { const v: U32 = 4294967295 as U32; return v; };
const u64hi = @comptime { const v: uint64 = 9223372036854775808; return v as U64; };
const u64max = @comptime { const v: uint64 = 18446744073709551615; return v as U64; };
const viaFn = topLamports();
const f32v = @comptime { const v: F32 = 2.5 as F32; return v; };
const f64v = @comptime { const v: F64 = 1.5 as F64; return v; };
const email = @comptime { const v: Email = "a@b" as Email; return v; };
const flag = @comptime { const v: Flag = true as Flag; return v; };

const keepI8: I8 = i8v;
const keepI16: I16 = i16v;
const keepI32: I32 = i32v;
const keepI64: I64 = i64v;
const keepU8: U8 = u8v;
const keepU32: U32 = u32v;
const keepU64: U64 = u64max;
const keepFn: U64 = viaFn;
const keepF32: F32 = f32v;
const keepF64: F64 = f64v;
const keepEmail: Email = email;
const keepFlag: Flag = flag;

console.log(`signed ${keepI8 as int8} ${keepI16 as int16} ${keepI32 as int32} ${keepI64 as int64} sizes ${sizeof(i8v)} ${sizeof(i16v)} ${sizeof(i32v)} ${sizeof(i64v)} unsigned ${keepU8 as uint8} ${keepU32 as uint32} ${u64hi as uint64} ${keepU64 as uint64} ${keepFn as uint64} sizes ${sizeof(u8v)} ${sizeof(u32v)} ${sizeof(u64max)} float ${keepF32 as float32} ${keepF64 as float64} sizes ${sizeof(f32v)} ${sizeof(f64v)} named ${keepEmail as string} ${keepFlag as boolean}`);
