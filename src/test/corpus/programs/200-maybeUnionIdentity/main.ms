// @maxrss: 30
// @stdout: maybe-union-identity ok=1 a=2.5 b=1.5
// note: Maybe cache identity for anonymous payloads (checker/types.ms maybeCacheKey). LibA declares `number|string|null`, LibB `float32|string|null` — two structurally different anon unions under `| null`. The old key collapsed every anon composite to 'p'+kind, so whichever module checked first claimed the Maybe type and the other inherited its payload Type object wholesale: LibB's `v as float32` then had no float32 member to select and codegen emitted a raw C cast on the union struct — clang: "operand of type 'msUnion_gddi8r' where arithmetic or pointer type is required". Found as the neon+yoga combined-build failure (yoga FlexStyle width/height/margin all miscompiled, 2026-07-27); same lossy key also fused Maybe<number[]> vs Maybe<string[]> (latent). Fix: structural suffix via checker typeKey (Union/Span/SizedArray arms added) for anon Union/Array/Tuple/Span/SizedArray payloads.

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
