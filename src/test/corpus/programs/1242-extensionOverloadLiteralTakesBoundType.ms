// @stdout: 166 166 5 200
// @stdout: 166 166 5 200
class M {}
class Box {}

function mn<T>(this typeof M, a: T, b: T): T { return a < b ? a : b; }
function mn(this typeof M, a: float64, b: float64): float64 { return a < b ? a : b; }

function lo<T>(this b: Box, a: T, c: T): T { return a < c ? a : c; }
function lo(this b: Box, a: float64, c: float64): float64 { return a < c ? a : c; }

const u: uint64 = 300;
const i: int64 = 5;
const s: uint8 = 200;
const box = new Box();
console.log(M.mn(u, 166), M.mn(166, u), M.mn(i, 9), M.mn(s, 250));
console.log(box.lo(u, 166), box.lo(166, u), box.lo(i, 9), box.lo(s, 250));
