// @stdout: 7|8|4|1|3|2|9|1
import { first, count, apply } from "./box";
import { Pt, Kind } from "./kinds";
const pt: Pt = { x: 3, y: 4 };
let seen = 0;
const a = first<Pt>([pt, 7]);
const b = first<Kind>([Kind.Offline, 8]);
const c = apply<Pt>((): [Pt, int32] => [pt, 9], (v: Pt): void => { seen = v.x + v.y; });
const e = apply<Kind>((): [Kind, int32] => [Kind.Offline, 5], (v: Kind): void => { seen = seen + (v === Kind.Offline ? 1 : 0); });
console.log([a.x + 4, b === Kind.Offline ? 8 : 0, a.y, b, count<Pt>([pt, 3]), seen - 6, c, e - 4].join("|"));
