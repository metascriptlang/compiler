// @stdout: field=1/1 optional=9,t2/2 sub=1,5/2
// note: a call in front of `??` or `?.` in an instance field initializer runs once per construction: a nullable number, a `?.` read with a string fallback beside it, and a subclass whose parent field also has one.

let calls = 0;
function maybe(v: int32): int32 | null { calls = calls + 1; return v > 0 ? v : null; }
class Inner { w: int32 = 9; }
function inner(on: boolean): Inner | null { calls = calls + 1; return on ? new Inner() : null; }
function text(): string | null { calls = calls + 1; return "t" + calls.toString(); }

class Plain { v: int32 = maybe(1) ?? 0; }
class Chained { w: int32 = inner(true)?.w ?? 0; s: string = text() ?? "none"; }
class Sub extends Plain { u: int32 = maybe(-1) ?? 5; }

const p = new Plain();
const field = `${p.v}/${calls}`;
calls = 0;
const c = new Chained();
const optional = `${c.w},${c.s}/${calls}`;
calls = 0;
const s = new Sub();
const sub = `${s.v},${s.u}/${calls}`;
console.log(`field=${field} optional=${optional} sub=${sub}`);
