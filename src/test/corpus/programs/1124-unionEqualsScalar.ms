// Parity program — a union compared with a value of one primitive kind is true
// when the union holds a member of that kind and the member equals the value,
// whichever side the union is on, for == === != !==, and the operands are read
// once and in source order.
//
// @stdout: true false true false true false true false
// @stdout: true false true true false true
// @stdout: true false true false true false false true
// @stdout: true false false true
// @stdout: true false true false true false
// @stdout: calls=3 order=u,v
// @exit: 0

function pick(k: int32): int32 | string { return k > 0 ? 2 : "s"; }
function pickf(k: int32): float64 | string { return k > 0 ? 1.5 : "s"; }
function pickb(k: int32): boolean | string { return k > 0 ? true : "s"; }
function pickw(k: int32): int32 | float64 | string { return k == 0 ? "s" : k == 1 ? 2 : 2.5; }

const w = pick(1);
const v = pick(0);
console.log(w === 2, w === 3, w !== 3, w !== 2, w == 2, w == 3, w != 3, w != 2);
console.log(v === "s", v === "t", v !== "t", 2 === w, 3 === w, "s" === v);
const f = pickf(1);
const g = pickf(0);
console.log(f === 1.5, f === 2.5, 1.5 === f, g === 1.5, g === "s", g !== "s", f !== 1.5, g !== 1.5);
const b = pickb(1);
console.log(b === true, b === false, b !== true, b !== false);

const t1 = pickw(1);
const t2 = pickw(2);
const t0 = pickw(0);
console.log(t1 === 2, t1 === 2.5, t2 === 2.5, t2 === 2, t0 === "s", t0 === 2);
if (w === 2) console.log("then");
const z = w === 2 ? 1 : 0;
console.log(z);

let calls = 0;
let order = "";
function u(): int32 | string { calls += 1; order += "u,"; return 2; }
function val(): int32 { calls += 1; order += "v"; return 2; }
const same = u() === val();
const other = 3 === u();
console.log("calls=" + calls.toString() + " order=" + order.substring(0, 3));
