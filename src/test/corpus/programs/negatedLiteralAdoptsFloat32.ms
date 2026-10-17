// A negated literal next to a float32 operand adopts float32: whole and fractional floats, integers, every operator, parenthesized or not.
// @stdout: 3 3.5 3 -6 3 2 3 -3 -6 -16777216 -Infinity
function f1(x: float32): float32 { const b = x - -2.0; return b; }
function f2(x: float32): float32 { const b = x - -2.5; return b; }
function f3(x: float32): float32 { const b = x + -2.0; return b; }
function f4(x: float32): float32 { const b = x * -2.0; return b; }
function f6(x: float32): float32 { const b = x - (-2.0); return b; }
function g1(x: float32): float32 { return x - -1.0; }
function g2(x: float32): float32 { return x - -2; }
function g3(x: float32): float32 { return x * -1; }
function g4(x: float32): float32 { return -3.0 * x; }
const big = -16777216.0;
const z = -0.0;
console.log(f1(1), f2(1), f3(5), f4(3), f6(1), g1(1), g2(1), g3(3), g4(2), big, 1 / z);
