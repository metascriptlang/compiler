// Parity program — an untyped float constant goes into every float32 slot, and
// beside a float32 operand, as a float literal does: rounded once to the same
// float32 on every backend.
//
// @stdout: 0.10000000149011612 0.01666666753590107 0.3333333432674408 0.10000000149011612 0.10000000149011612 0.3333333432674408 0.10000000149011612 0.10000000149011612 0.30000001192092896 0.10000000149011612 3
// @stdout: 0.30000001192092896 0.30000001192092896 9 0.15000000596046448 210000
// @exit: 0

const K = 0.1;
const STEP = 1.0 / 60.0;
const THIRD = 1.0 / 3.0;
const ALIAS = K;
const C = 3;

struct Cell { w: float32; }

function pass(v: float32): float32 { return v; }
function back(): float32 { return THIRD; }
function orZero(v: float32 | null): float32 { return v ?? 0; }

let assigned: float32 = 1;
assigned = K;
const cell: Cell = { w: ALIAS };
const row: float32[] = [K, K * 3];
const label: float32 | string = K;
const maybe: float32 | null = C;

console.log(assigned, pass(STEP), back(), cell.w, row[0], pass(THIRD), orZero(K), `${label}`, row[1], pass(ALIAS), maybe);

let x: float32 = 3;
let y: float32 = 1.5;
y *= K;
const WIDE = 70000;
console.log(x * K, K * x, x * C, y, x * WIDE);
