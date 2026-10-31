// @stdout: 83
// @stdout: 1.5
// @stdout: 7
// @stdout: 2.5
// @stdout: null
function lengthF(n: int32): float32 | string | null { return n > 0 ? 83 : null; }
function wideF(x: float64): float64 | string | null { return x; }
function mixed(n: int32): int32 | string | null { return n; }
function plain(n: int32): float32 | string { return n as float32; }
const a = lengthF(1);
const b = wideF(1.5);
const c = mixed(7);
const d = plain(2);
const e = lengthF(1);
const f = lengthF(0);

console.log(String(a as number));
console.log(String(b as number));
console.log(String(c as float64));
console.log(String((d as number) + 0.5));
console.log(String(e as float64));
console.log(f == null ? "null" : "set");
