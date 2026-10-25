// @stdout: inits=[side,mixed,made] sum=26 k=none
// note: a module runs its top level only when some import of it is a side-effect import or uses one of its bindings as a value. `quiet`, the barrel `hub` and its `deep`, the namespace `nsmod` and the class `cls` are imported only for types and never run; `mixed` is imported twice, once with a value, and runs once.

import { inits } from "./lib/trace";
import { Shape } from "./lib/quiet";
import "./lib/side";
import { Pt, mk } from "./lib/mixed";
import { Pt as Point } from "./lib/mixed";
import { Box } from "./lib/hub";
import * as ns from "./lib/nsmod";
import { K } from "./lib/cls";
import { Made } from "./lib/made";

const s: Shape = { w: 2 };
const p: Pt = mk(3, 4);
const q: Point = { x: 1, y: 1 };
const b: Box = { v: 5 };
const t: ns.T = { n: 3 };
const k: K | null = null;
console.log(`inits=[${inits.join(",")}] sum=${s.w + p.x + p.y + q.x + q.y + b.v + t.n + new Made().n} k=${k == null ? "none" : "some"}`);
