import { Slot as BaseSlot } from "./a";

class Slot {
	w: int32 = 2;
	constructor(w: int32) { this.w = w; }
}
class Child extends BaseSlot {
	c: int32 = 3;
	constructor(c: int32) { super(c + 1); this.c = c; }
}
class Plain {
	m: int32 = 22;
}
export function sb(): int32 { const k = new Child(5); return new Slot(7).w + k.v + k.c + new Plain().m; }
