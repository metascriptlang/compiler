// @stdout: 2 7 5 48|102 107 105 148
// note: `&`, `|`, `^` and `<<` extension operators on two exported types, used from another
// module. Per-module ES emit gave `&`, `|` and `^` one binding name, a duplicate export.
import { V, W } from "./lib";

const a: V = { x: 6 };
const b: V = { x: 3 };
const c: W = { x: 6 };
const d: W = { x: 3 };
console.log(`${(a & b).x} ${(a | b).x} ${(a ^ b).x} ${(a << b).x}|${(c & d).x} ${(c | d).x} ${(c ^ d).x} ${(c << d).x}`);
