const PREFIX = "p:";
function tagOf(n: int32): string { return PREFIX + n.toString(); }

export class Base {
	u: int32;
	w: string;
	constructor(u: int32, w: string = tagOf(u)) {
		this.u = u * 2;
		this.w = w;
	}
	describe(): string { return `${this.u}/${this.w}`; }
}

export class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}

export class Slot {
	s: int32 = 1;
	constructor(s: int32) { this.s = s + 100; }
}
