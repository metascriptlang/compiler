export class Slot {
	v: int32 = 1;
	constructor(v: int32) { this.v = v; }
}
class Plain {
	n: int32 = 11;
}
export function sa(): int32 { return new Slot(4).v + new Plain().n; }
