// Parity program — `f?.(x)` and `a?.[i]` start an optional chain like `o?.p`: a null
// callee or array yields null without evaluating the arguments, a present one is called
// or indexed. The checker refused `?.(` and `?.[` as a member access with an empty name.
//
// @stdout: 1 -1 1 -1
// @stdout: 3 -1 5
// @stdout: 7 -1 2 -1
// @stdout: 1 0
// @exit: 0

type O = { f: ((x: int32) => int32) | null };
type P = { g: ((...xs: int32[]) => int32) | null };
type Q = { h: ((x: int32) => int32) | null };

let evaluated = 0;
function tick(): int32 { evaluated = evaluated + 1; return 5; }
function g(x: int32): int32 { return x; }
function sum(...xs: int32[]): int32 { let t = 0; for (const x of xs) t = t + x; return t; }
function pick(on: boolean): ((x: int32) => int32) | null { return on ? g : null; }

const m: ((x: int32) => int32) | null = g;
const none: ((x: int32) => int32) | null = null;
const o: O = { f: g };
const e: O = { f: null };
console.log(m?.(1) ?? -1, none?.(1) ?? -1, o.f?.(1) ?? -1, e.f?.(1) ?? -1);

const p: P = { g: sum };
const pn: P = { g: null };
console.log(p.g?.(1, 2) ?? -1, pn.g?.(1, 2, 3) ?? -1, p.g?.(5) ?? -1);

function maybe(on: boolean): int32[] | null { return on ? [7, 2] : null; }
const xs = maybe(true);
const ys = maybe(false);
console.log(xs?.[0] ?? -1, ys?.[0] ?? -1, xs?.[1] ?? -1, ys?.[tick()] ?? -1);

const q: Q | null = { h: g };
console.log(q?.h?.(1) ?? -1, evaluated);
