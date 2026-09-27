// @stdout: 7 u8:7 i64 i64 f32:2
// Overload scoring knows an integer literal: an in-range `7` matches an overloaded uint8 formal
// (it was refused as a plain int32), and an int32 argument or literal prefers int64 over float64
// (both scored IntConv, so the call was ambiguous). The reference scores an in-range literal
// isFromIntLit (sigmatch.nim handleRange) and a non-literal int into a float below any integer
// conversion (handleFloatRange).

function tu8(x: uint8): string { return x.toString(); }
function ov(x: uint8): string { return "u8:" + x.toString(); }
function ov(x: string): string { return "s:" + x; }
function f(x: int64): string { return "i64"; }
function f(x: float64): string { return "f64"; }
function g(x: float32): string { return "f32:" + x.toString(); }
function g(x: string): string { return "s:" + x; }

const n: int32 = 5;
console.log(tu8(7) + " " + ov(7) + " " + f(n) + " " + f(5) + " " + g(2));
