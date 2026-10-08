// @stdout: float64 7|string s|float64 7|float64 7|int16 200|int64 7|float32 -3,boolean|float64 7|scalar 7
// note: a union member reaching the target only by a lossless numeric widening converts: int32 into float64 by declaration, argument, return and `as`, uint8 into int16, int32 into int64, int16 into float32, into a nullable float64 and `as` a lone float64. A lossy pair (int64 into float64) is refused by the checker (checker3pass unionConversion). Same output on C, JS and the Raiser.
function wire(c: int32): int32 | string { return c == 0 ? 7 : "s"; }
function small(c: int32): uint8 | string { return c == 0 ? 200 : "u"; }
function half(c: int32): int16 | boolean { return c == 0 ? -3 : true; }
function showF(u: float64 | string): string { return typeof u === "string" ? "string " + u : "float64 " + String(u); }
function showI(u: int16 | string): string { return typeof u === "string" ? "string " + u : "int16 " + String(u); }
function showW(u: int64 | string): string { return typeof u === "string" ? "string " + u : "int64 " + String(u); }
function showH(u: float32 | boolean): string { return typeof u === "boolean" ? "boolean" : "float32 " + String(u); }
function showN(u: float64 | null): string { return u == null ? "null" : "float64 " + String(u); }
function ret(c: int32): float64 | string { const w = wire(c); return w; }
const out: string[] = [];
const f: float64 | string = wire(0);
out.push(showF(f));
out.push(showF(wire(1)));
out.push(showF(ret(0)));
out.push(showF(wire(0) as float64 | string));
out.push(showI(small(0)));
out.push(showW(wire(0)));
out.push(showH(half(0)) + "," + showH(half(1)));
out.push(showN(wire(0) as float64 | null));
out.push("scalar " + String(wire(0) as float64));
console.log(out.join("|"));
