// @stdout: 5 b 2 | 0 3 | 9 w x 9 o | base 42 1 7 4 | 1 2 5 3 0 | 2 3 4 | 10 10 0
// note: an object literal of a class type runs the initializer of every field it omits, in the class's module, once per literal, as `new` does: own and inherited fields, a generic class, a nested literal, a call and a private constant of another module. Same output on C, JS and the Raiser.
import { Lib, madeCount } from "./fieldInitLib";

const K: int32 = 10;

function zero<T>(): T[] {
	return [];
}

class C { k: int32 = 5; name: string = "a"; xs: int32[] = [1, 2]; }
class G<T> { items: T[] = []; count: int32 = 3; }
class Z<T> { xs: T[] = zero<T>(); k: int32 = K; }
class Inner { v: int32 = 9; ws: string[] = ["w"]; }
class Outer { inner: Inner = {}; label: string = "o"; }
struct P { x: int32; y: int32; }
class H { p: P = { x: 1, y: 2 }; q: P; }

class M {
	k: int32 = K;

	make(): M {
		const K: int32 = 99;
		const m: M = {};
		return m;
	}
}

function build<T>(): Z<T> {
	const z: Z<T> = {};
	return z;
}

const c: C = { name: "b" };
const g: G<string> = {};
const o: Outer = { label: "x" };
const o2: Outer = { inner: {} };
const a: Lib = { n: 1 };
const b: Lib = { n: 2, ys: [7] };
const h: H = { q: { x: 5, y: 6 } };
const pp: P = { x: 3 };
let loop = "";
for (let i = 0; i < 3; i += 1) {
	const l: Lib = { n: i };
	loop += i == 0 ? `${l.ys[0]}` : ` ${l.ys[0]}`;
}
const made = madeCount();
console.log(`${c.k} ${c.name} ${c.xs.length} | ${g.items.length} ${g.count} | ${o.inner.v} ${o.inner.ws[0]} ${o.label} ${o2.inner.v} ${o2.label} | ${a.tag} ${a.secret} ${a.ys[0]} ${b.ys[0]} ${made} | ${h.p.x} ${h.p.y} ${h.q.x} ${pp.x} ${pp.y} | ${loop} | ${new M().make().k} ${build<string>().k} ${build<int32>().xs.length}`);
