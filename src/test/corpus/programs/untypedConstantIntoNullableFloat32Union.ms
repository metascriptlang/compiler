// @stdout: 24 24 24 24 0.5 3 -24 24
// @stdout: number number number number number number number number
// @stdout: true true true
const EDGE = 24;
const HALF = 0.5;
const TENTH = 0.1;
const a: float32 = EDGE;
const b: float32 | null = EDGE;
const c: float32 | string | null = 24;
const d: float32 | string | null = EDGE;
const e: float32 | string | null = HALF;
const f: float32 | string | null = 7 / 2;
const g: float32 | string | null = -EDGE;
const h: number | string | null = EDGE;
console.log(a, b, c, d, e, f, g, h);
console.log(typeof a, typeof b, typeof c, typeof d, typeof e, typeof f, typeof g, typeof h);

const rounded: float32 = TENTH;
const viaUnion: float32 | string | null = TENTH;
const viaLiteral: float32 | string | null = 0.1;
function widen(v: float32 | string | null): float32 | string | null { return v; }
console.log(viaUnion === rounded, viaLiteral === rounded, widen(TENTH) === rounded);
