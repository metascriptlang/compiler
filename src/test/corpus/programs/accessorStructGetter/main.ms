// @stdout: 1 2\n2 1\n3 4\n1 2 3 4\n9 8 1\n2
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
console.log(String(uv.x), String(uv.y));
const vu = v.yx;
console.log(String(vu.x), String(vu.y));
console.log(String(v.zw.x), String(v.zw.y));
console.log(String(v.x), String(v.y), String(v.z), String(v.w));
const n = next().xy;
console.log(String(n.x), String(n.y), String(calls));
console.log(String(v.xy.y));
