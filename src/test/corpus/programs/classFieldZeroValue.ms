// @stdout: 0 0 false [] none 0 0 | 0 0 false [] none 3 | 0 [] none
// note: a class field without initializer reads its zero value after `new`, a struct field included and through a subclass, and a literal of a generic class leaves its omitted value and nullable fields at zero. Same output on C, JS and the Raiser.
class Item { v: int32 = 7; }
struct Pt { x: int32; inner: In; }
struct In { y: float64; }

class Base {
	n: int32;
	big: int64;
	ok: boolean;
	s: string;
	opt?: Item;
	p: Pt;
}

class Sub extends Base {
	k: int32 = 3;
}

class Gen<T> {
	n: int32;
	label: string;
	xs: T[];
	maybe: Item | null;
}

const b = new Base();
const c = new Sub();
const g: Gen<string> = { xs: [] };
console.log(`${b.n} ${b.big} ${b.ok} [${b.s}] ${b.opt == null ? "none" : "some"} ${b.p.x} ${b.p.inner.y} | ${c.n} ${c.big} ${c.ok} [${c.s}] ${c.opt == null ? "none" : "some"} ${c.k} | ${g.n} [${g.label}] ${g.maybe == null ? "none" : "some"}`);
