export function label(name: string, shown: string = name): string {
	return name + "/" + shown;
}

export function triple(a: string, b: string = a, c: string = a + b): string {
	return a + "," + b + "," + c;
}

export struct S { n: int32; }

export function grow(this s: S, by: int32 = s.n): int32 {
	return s.n + by;
}

export class Pt {
	a: string;
	b: string;
	constructor(a: string, b: string = a) {
		this.a = a;
		this.b = b;
	}
}

export class Box {
	show(a: string, b: string = a): string {
		return a + ":" + b;
	}
}

export function applyTo(v: int32, f: (x: int32) => int32 = (x: int32): int32 => x + v): int32 {
	return f(v);
}
