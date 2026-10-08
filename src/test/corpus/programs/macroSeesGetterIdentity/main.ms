// @stdout: get_xy:struct get_yx:struct|5
// @exit: 0
// note: a macro reading a checked body sees a struct getter read `v.xy` as the call it is, and `getImpl` of its callee is the getter's own declaration with its checked result type, so a shader emitter needs no lookup by property spelling.

import { getters } from "./inspect";

struct Vec2 { x: float32; y: float32; }
struct Vec4 {
	x: float32;
	y: float32;
	z: float32;
	w: float32;
	get xy(): Vec2 { return { x: this.x, y: this.y }; }
	get yx(): Vec2 { return { x: this.y, y: this.x }; }
}

function frag(v: Vec4): float32 { return v.xy.x + v.yx.x; }

const out: string[] = [];
out.push(getters(frag));
out.push(String(frag({ x: 2.0, y: 3.0, z: 0.0, w: 0.0 })));
console.log(out.join("|"));
