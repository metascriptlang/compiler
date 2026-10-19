// @stdout: 42 ra local pv
// @stdout: ra {"kind":"A","r":"ra"}
// @stdout: true pv {"ok":true,"value":"pv"}
// @stdout: 5 {"ok":true,"value":5}
// @stdout: 24 24 24 24 24 24
// @stdout: 7,42,ra,
// @stdout: obj3 obj3 lit
// note: a union declared in `shapes.ms` is built, narrowed, sized and stored in an array by `main.ms`, and an object is converted into an arm of it in both modules, so the member-wise arm routine is emitted in the module that converts, and the arm layout agrees across the module boundary.

import { K, S, P, mkS, mkP, fromObject, readS, readP, sizes, okR } from "./shapes";
const s: S = { kind: K.B, n: 42 };
const p: P = { ok: false, error: "local" };
console.log(readS(s), readS(mkS(true)), readP(p), readP(mkP(true)));
const t = mkS(true);
if (t.kind === K.A) { const u = t; console.log(u.r, JSON.stringify(u)); }
const q = mkP(true);
if (q.ok) { const w = q; console.log(w.ok, w.value, JSON.stringify(w)); }
const r = okR();
if (r.ok) console.log(r.value, JSON.stringify(r));
console.log(sizes(), `${sizeof(S)} ${sizeof(P)} ${sizeof(Result<int32, string>)}`);
const arr: S[] = [mkS(false), s, mkS(true)];
let acc = "";
for (const e of arr) acc = acc + readS(e) + ",";
console.log(acc);
const failed: { ok: false; error: string } = { ok: false, error: "obj" + `${arr.length}` };
console.log(readP(failed), readP(fromObject(failed)), readP(fromObject({ ok: false, error: "lit" })));
