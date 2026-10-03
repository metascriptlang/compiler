// @xfail(raiser): raiser runtime error: cannot evaluate 'super' at comptime: symbol kind is Function
// note: new, super, defaulted and rest parameters, generic instances and a class imported from another module each construct through their constructor's own routine
import { Shape, Square, Crate, Marker } from "./shapes";

class Plain {
	n: number;
	constructor(n: number) { this.n = n; }
}

class Child extends Plain {
	m: number;
	constructor(n: number, m: number) {
		super(n);
		this.m = m;
	}
}

class Grandchild extends Child {
	constructor() { super(7, 8); }
}

class Defaults {
	a: number;
	b: string;
	constructor(a: number = 5, b: string = "dflt") { this.a = a; this.b = b; }
}

class Fields {
	x: number = 3;
	y: string = "yy";
}

class Rest {
	total: number = 0;
	constructor(...xs: number[]) {
		for (const x of xs) this.total += x;
	}
}

const p = new Plain(1);
console.log("plain", p.n);
const c = new Child(2, 3);
console.log("child", c.n, c.m);
const g = new Grandchild();
console.log("grand", g.n, g.m);
const d1 = new Defaults();
const d2 = new Defaults(9);
console.log("defaults", d1.a, d1.b, d2.a, d2.b);
const f = new Fields();
console.log("fields", f.x, f.y);
const r = new Rest(1, 2, 3);
console.log("rest", r.total);

const s = new Shape("tri");
const q = new Square(2);
console.log("shape", s.describe(), q.describe(), q.edge);
const k1 = new Crate<string>("a");
const k2 = new Crate<number>(4, 6);
console.log("crate", k1.item, k1.count, k2.item, k2.count);
const m = new Marker();
console.log("marker", m.tag);
