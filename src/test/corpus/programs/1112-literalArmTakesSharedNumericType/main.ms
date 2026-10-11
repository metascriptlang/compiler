// @stdout: 4 2 2 8 6 2 6 3 2 1
// note: CK-135 at a join — a literal arm of a ternary, a match, an array literal or a try/catch
// value takes the numeric type its other arms share, as a literal operand does beside a typed one.
// `(p == 0 ? 1.0 : a) * b` with float32 a, b was refused as an implicit float64 -> float32 narrowing.
const a: float32 = 0.5;
const b: float32 = 4.0;
const u: uint8 = 200;
function tern(p: int32): float32 { return (p == 0 ? 1.0 : a) * b; }
function ternR(p: int32): float32 { return (p == 0 ? a : 2.0) * b; }
function arm(p: int32): float32 { const k = match (p) { 0 => 1.5, _ => a }; return k * b; }
function arr(): float32 { const xs = [a, 1.5, 2.0]; return xs[1] * b; }
function small(p: int32): uint8 { const v = p == 0 ? 3 : u; return v; }
function made(n: int32): Result<float32, string> { return n > 0 ? Result.ok(a) : Result.err("no"); }
function caught(n: int32): float32 { const v = try made(n) catch 0.25; return v * b; }
console.log(`${tern(0)} ${tern(1)} ${ternR(0)} ${ternR(1)} ${arm(0)} ${arm(1)} ${arr()} ${small(0)} ${caught(1)} ${caught(0)}`);
