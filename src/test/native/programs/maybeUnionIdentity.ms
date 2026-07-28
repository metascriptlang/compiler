// maybe-union-identity: two modules declare structurally DIFFERENT anonymous
// unions under `| null` — LibA `number|string`, LibB `float32|string`. The
// checker's Maybe cache must key them separately; a lossy key ("p"+kind) fuses
// them, LibB inherits LibA's number|string payload, and `v as float32` in
// readB has no float32 member to select (C: cast applied to a union struct).
// Found via neon+yoga combined build (msUnion_gddi8r collision, 2026-07-27).

import { BoxA, readA } from "./maybeUnionIdentityLibA";
import { BoxB, readB } from "./maybeUnionIdentityLibB";

const a: BoxA = { w: 2.5 };
const b: BoxB = { w: 1.5 as float32 };
const sa: BoxA = { w: "str" };
const sb: BoxB = { w: "str" };
const na: BoxA = { w: null };

const av = readA(a);
const bv = readB(b);
let ok = true;
if (av !== 2.5) ok = false;
if (bv !== (1.5 as float32)) ok = false;
if (readA(sa) !== -2) ok = false;
if (readB(sb) !== (-2.0 as float32)) ok = false;
if (readA(na) !== -1) ok = false;

console.log("maybe-union-identity ok=" + (ok ? "1" : "0") + " a=" + av.toString() + " b=" + bv.toString());
