// Positional `new C(a, b)` on a class WITHOUT a user constructor must carry
// the args on BOTH backends. C always materialized them inline; JS dropped
// them silently (fields undefined, nested news crash node) until newExprLower
// moved the materialization into the shared transform pipeline. The [js] mode
// is the half that was red; the drc/orc runs pin the hoisted temp + field
// assignments to a clean RC balance.
// GUARD-JS

class Pt { x: number; y: number; z: number = 3; }
class Holder { tag: number; inner: Pt; }
class WithCtor { v: number; constructor(v: number) { this.v = v; } }

function mk(): Pt { return new Pt(8, 9); }
function pass(p: Pt): number { return p.x * 100 + p.y * 10 + p.z; }

const p = new Pt(1, 2);
const obsP = p.x * 100 + p.y * 10 + p.z;
console.log(obsP);

const h = new Holder(4, new Pt(5, 6));
const obsH = h.tag * 1000 + h.inner.x * 100 + h.inner.y * 10 + h.inner.z;
console.log(obsH);

const m = mk();
const obsM = m.x * 100 + m.y * 10 + m.z;
console.log(obsM);

const obsArg = pass(new Pt(7, 8));
console.log(obsArg);

const obsCtor = new WithCtor(42).v;
console.log(obsCtor);

let bad = 0;
if (obsP !== 123) { bad += 1; }
if (obsH !== 4563) { bad += 1; }
if (obsM !== 893) { bad += 1; }
if (obsArg !== 783) { bad += 1; }
if (obsCtor !== 42) { bad += 1; }
if (bad === 0) { console.log("GUARD-OK"); }
