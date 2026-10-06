// @stdout: 1 1 n=5 4,8 on null 5 0
// note: a method without a return annotation returns what its body returns, as a free function does: a number, a string, a struct, a nullable, void and a static method. Same output on C, JS and the Raiser.
struct Point { x: int32; y: int32; }

class Base {
	n: int32 = 4;
	get() { return 1; }
	label() { return "n=" + this.n.toString(); }
	point() { return { x: this.n, y: this.n * 2 } as Point; }
	maybe(on: boolean) { if (on) return "on"; return null; }
	bump() { this.n += 1; }
	static zero() { return 0; }
}

const s = new Base();
const n: int32 = s.get();
const p = s.point();
const off = s.maybe(false);
s.bump();
console.log(`${s.get()} ${n} ${s.label()} ${p.x},${p.y} ${s.maybe(true)} ${off == null ? "null" : off} ${s.n} ${Base.zero()}`);
