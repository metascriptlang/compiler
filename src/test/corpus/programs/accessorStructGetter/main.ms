// @stdout: 1 2|2 1|3 4|1 2 3 4|9 8 1|2
// @exit: 0
// note: a struct `get xy()` is a value-type property read: `v.xy` and `v.yx` return new values in their own component order and leave `v` unchanged, a getter of an imported struct works without importing anything but the struct, a getter result chains into a field read, and a receiver with side effects is evaluated once. A getter in a struct body used to be a parse error.

import { Vec4 } from "./vec";

let calls = 0;
function next(): Vec4 {
	calls += 1;
	return { x: 9.0, y: 8.0, z: 7.0, w: 6.0 };
}

const v: Vec4 = { x: 1.0, y: 2.0, z: 3.0, w: 4.0 };
const uv = v.xy;
const out: string[] = [];
out.push([String(uv.x), String(uv.y)].join(" "));
const vu = v.yx;
out.push([String(vu.x), String(vu.y)].join(" "));
out.push([String(v.zw.x), String(v.zw.y)].join(" "));
out.push([String(v.x), String(v.y), String(v.z), String(v.w)].join(" "));
const n = next().xy;
out.push([String(n.x), String(n.y), String(calls)].join(" "));
out.push(String(v.xy.y));
console.log(out.join("|"));
