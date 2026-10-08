// @stdout: 5 true|6.5|3 2|10 1|12
// @exit: 0
// note: a class `get x()` / `set x(v)` pair runs as TypeScript runs it: `n.x = v` calls the setter, `n.x` the getter, `n.x += v` reads through the getter and writes through the setter once each, an accessor declared on a base class serves a derived instance, and a setter with no return annotation is a void routine. The accessors used to parse and vanish, so the first read stopped the build with "Property 'x' does not exist".

class Node2 {
	private _x: float32 = 0.0;
	dirty: boolean = false;
	reads: int32 = 0;
	writes: int32 = 0;
	get x(): float32 { this.reads += 1; return this._x; }
	set x(v: float32) { this.writes += 1; this._x = v; this.dirty = true; }
}

class Counter {
	protected n: int32 = 0;
	get count(): int32 { return this.n; }
	set count(v: int32) { this.n = v; }
}

class Labeled extends Counter {
	label: string = "L";
}

const n = new Node2();
n.x = 5.0;
const out: string[] = [];
out.push([String(n.x), String(n.dirty)].join(" "));
n.x += 1.5;
out.push(String(n.x));
out.push([String(n.reads), String(n.writes)].join(" "));

const l = new Labeled();
l.count = 10;
out.push([String(l.count), String(l.label.length)].join(" "));
const holder = { inner: l };
holder.inner.count += 2;
out.push(String(l.count));
console.log(out.join("|"));
