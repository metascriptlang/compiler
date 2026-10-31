// @stdout: 0 0.5 2 0.25 1 Infinity -Infinity
// @stdout: 0 1 Infinity -Infinity 166 300
type Pad = { top: float32; size: int32 };
function clamp(value: float32): float32 { return Math.max(0.0, Math.min(value, 1.0)); }
function blend(a: float32, b: float32): float32 { return a * b + Math.max(a * b, 0.0); }
function floor0(p: Pad): Pad { return { ...p, size: 1, top: Math.max(0.0, p.top) }; }
function fit(a: float32, b: float32): float32 { const fits: float32 = Math.min(a, b); return Math.min(1.0, fits); }
const nz32: float32 = -0.0;
const pz32: float32 = 0.0;
const nz: float64 = -0.0;
const pz: float64 = 0.0;
const big: uint64 = 300;
console.log(clamp(-3.0), clamp(0.5), floor0({ top: 2.0, size: 0 }).top, blend(0.5, 0.5) - 0.25, fit(2.0, 3.0), 1 / Math.max(nz32, pz32), 1 / Math.min(pz32, nz32));
console.log(floor0({ top: -4.0, size: 0 }).top, Math.max(1, 2) - 1, 1 / Math.max(nz, pz), 1 / Math.min(pz, nz), Math.min(big, 166), Math.max(big, 166));
