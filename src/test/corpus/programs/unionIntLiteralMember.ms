// @stdout: 7 8 9 3 2.5 1.5
// note: an integer literal into a union with an integer and a float member is stored as the integer member, whatever order the members are written in: return, call argument, assignment, a narrow integer and float32. Same output on C, JS and the Raiser.
function floatFirst(): float64 | int32 { return 7; }
function intFirst(k: int32): int32 | float64 { if (k == 0) return 8; return 1.5; }
function takes(v: float64 | int32): int32 { return v as int32; }
function small(): float32 | int8 { return 3; }
function fl(): float64 | int32 { return 2.5; }
let a: float64 | int32 = 1.5;
const keepFloat = a as float64;
a = 9;
console.log([String(floatFirst() as int32), String(intFirst(0) as int32), String(a as int32), String(small() as int8), String(fl() as float64), String(keepFloat)].join(" "));
