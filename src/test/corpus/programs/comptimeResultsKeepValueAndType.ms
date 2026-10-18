// @stdout: signed -128 -32768 -2147483648 -1 -9223372036854775808 sizes 1 2 4 8 unsigned 9223372036854775808 18446744073709551615 8 folded -5 -5 1e+300 A true nested 18446744073709551615 18446744073709551615 -3
// note: a comptime result becomes a literal with its own value and type: each signed width at its negative end, uint64 past 2^63, a float, a char and an enum, from a block, a @comptime function and a macro, and inside an array and a struct.
import { Node, NodeKind } from "std/meta";

enum Color { Red, Green, Blue }
struct Wide { u: uint64; i: int64; }

macro minusFive(at: Node): Node { return { kind: NodeKind.NumberLiteral, line: at.line, column: at.column, value: -5, isFloat: false }; }
@comptime function negate(n: int64): int64 { return 0 - n; }
@comptime function pick(): Color { return Color.Blue; }

const i8v = @comptime { const v: int8 = -128; return v; };
const i16v = @comptime { const v: int16 = -32768; return v; };
const i32v = @comptime { const v: int32 = -2147483648; return v; };
const i64v = @comptime { const v: int64 = -1; return v; };
const i64min = @comptime { const v: int64 = -9223372036854775807 - 1; return v; };
const u64hi = @comptime { const v: uint64 = 9223372036854775808; return v; };
const u64max = @comptime { const v: uint64 = 18446744073709551615; return v; };
const viaFn = negate(5);
const viaMacro: int64 = minusFive(0);
const huge = @comptime { const v: float64 = 1e300; return v; };
const letter = @comptime { return 65 as char; };
const color = pick();
const elements = @comptime { const xs: uint64[] = [18446744073709551615, 1]; return xs; };
const fields = @comptime { const w: Wide = { u: 18446744073709551615, i: -3 }; return w; };
console.log(`signed ${i8v} ${i16v} ${i32v} ${i64v} ${i64min} sizes ${sizeof(i8v)} ${sizeof(i16v)} ${sizeof(i32v)} ${sizeof(i64v)} unsigned ${u64hi} ${u64max} ${sizeof(u64hi)} folded ${viaFn} ${viaMacro} ${huge} ${letter} ${color == Color.Blue} nested ${elements[0]} ${fields.u} ${fields.i}`);
