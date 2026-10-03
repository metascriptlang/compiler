// Parity program — a number goes into the union member that holds it best,
// ranked as an overload is, as a declaration, an assignment or an argument, on
// every backend.
//
// @stdout: 6 3 8 8 0.10000000149011612 4 3 1.5 8 0.10000000149011612 number number
// @stdout: 3 7
// @exit: 0

function twice(v: number | string): number { if (typeof v === "number") return v * 2; return -1; }
function next(v: int32 | string): int32 { if (typeof v === "number") return v + 1; return -1; }
function same(v: float32 | string): number { if (typeof v === "number") return v; return -1; }
function shown(v: number | string): number { return typeof v === "number" ? v : -1; }

let i: int32 = 3;
let h: int16 = 7;
let f: float32 = 1.5;
const C = 4;
const K = 0.1;

const a: number | string = i;
let b: number | string = "x";
b = f;
const c: int32 | string = h;
const d: float32 | string = K;

console.log(twice(i), twice(f), next(h), twice(C), same(K), same(C), shown(a), shown(b), next(c), same(d), typeof a, typeof c);

const wide: int64 | number = i;
const half: int64 | number = h;
console.log(wide, half);
