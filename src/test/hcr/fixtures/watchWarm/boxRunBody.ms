let trail = "";

class Plain {
	h: int32;
	constructor(h: int32 = 4) { this.h = h; }
}

class Figure {
	area(): int32 { return 1; }
}

class Circle extends Figure {
	area(): int32 { return 3; }
}

class Bag<T> {
	n: T;
	h: int32;
	constructor(n: T, h: int32) { this.n = n; this.h = h; }
}

function onDestroy<T>(this self: Bag<T>): void {
	trail = trail + " hook" + self.h.toString();
}

class Remote<T> {
	v: T;
	h: int32;
	constructor(v: T, h: int32) { this.v = v; this.h = h; }
	onDestroy(): void { trail = trail + " r" + this.h.toString(); }
}

function figureArea(f: Figure): int32 {
	return f.area();
}

function run(): int32 {
	const p = new Plain();
	const g = new Bag<float64>(0.5, 2);
	const q = new Remote<int32>(1, 6);
	return p.h + g.h + q.h + figureArea(new Circle()) + 1;
}

export function boxValue(): int32 {
	const v = run();
	return (v + trail.length) as int32;
}
