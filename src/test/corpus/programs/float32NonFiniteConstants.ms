// @stdout: Infinity|-Infinity,0,1,Infinity|-Infinity|NaN
// @stdout: Infinity|-Infinity|NaN|Infinity
// @stdout: Infinity|-Infinity|NaN|true
function take(v: float32): string { return "" + v; }
function pick(): float32 { return -Infinity; }
class Range { lo: float32 = -Infinity; hi: float32 = Infinity; }

const a: float32 = Infinity;
const b: float32[] = [-Infinity, 0, 1, Infinity];
const c: float32 = -Infinity;
const d: float32 = NaN;
console.log([a, b.join(","), c, d].join("|"));

const e: float32 | null = Infinity;
const f: float32 | null = -Infinity;
const g: float32 | string | null = NaN;
const h: float32 | string | null = Infinity;
console.log([e, f, g, h].join("|"));

const r = new Range();
console.log([take(Infinity), take(-Infinity), take(NaN), pick() === -Infinity && r.hi === Infinity && r.lo === -Infinity].join("|"));
