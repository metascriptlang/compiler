// @stdout: g=0.5
// note: main imports `Rgba` only as a type, so `types.ms` and the C-header binding `gpu.ms` it imports are compiled but never evaluated. The JS bundle used to evaluate them and die on `K_SLOTS`, which only C can read; every backend now prints the same line.

import { Rgba } from "./types";
const c: Rgba = { r: 1.0, g: 0.5 };
console.log(`g=${c.g}`);
