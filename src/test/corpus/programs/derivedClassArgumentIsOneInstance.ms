// @stdout: proxy=1 2 cell=1 2 2 1
// note: a generic instantiated with a class that extends another, once from a signature written inside that class (`child<V>(): Cell<V, H<V>>`) and once from outside it, is one instance. Before, the instance argument formed inside the class body had not yet been marked as holding inherited fields, so the two were told apart by that flag and the second was emitted under the same name: JS refused the module (`Identifier 'ProxyCell_…' has already been declared`); C printed the right line. Same output on every backend.
import { isObject } from "std/typetraits";

interface Row { i: int32; }
interface Root { rows: Row[]; }

type At<T, K extends keyof T> = T[K];
type Wrap<V> = V extends object ? Proxy<V, Traps<V> > : V;

class Base {}

export class Traps<T> extends Base {
	constructor() { super(); }
	get<K extends keyof T>(target: T, key: K): Wrap<T[K]> {
		const v = Reflect.get(target, key);
		when (isObject<At<T, K>>()) { return new Proxy(v, this.child(v)); } else { return v; }
	}
	child<V>(v: V): Traps<V> { return new Traps<V>(); }
}

function store<T>(v: T): Proxy<T, Traps<T> > { return new Proxy(v, new Traps<T>()); }

class Cell<T, H> { t: T; h: H; constructor(t: T, h: H) { this.t = t; this.h = h; } }

function handlerOf<T, H>(c: Cell<T, H>): H { return c.h; }

class Held<T> extends Base {
	n: int32 = 0;
	constructor() { super(); }
	child<V>(v: V): Cell<V, Held<V> > {
		const c = new Cell<V, Held<V> >(v, new Held<V>());
		const h = handlerOf(c);
		h.n = 1;
		return c;
	}
}

function made<T>(v: T): Cell<T, Held<T> > {
	const c = new Cell<T, Held<T> >(v, new Held<T>());
	const h = handlerOf(c);
	h.n = 2;
	return c;
}

const rows = store<Row[]>([{ i: 1 }]);
const root = store<Root>({ rows: [{ i: 2 }] });
const first: int32[] = [1];
const second: int32[] = [2];
const a = made<int32[]>(first);
const b = new Held<string>().child(second);
console.log(`proxy=${rows[0].i} ${root.rows[0].i} cell=${a.t[0]} ${b.t[0]} ${handlerOf(a).n} ${handlerOf(b).n}`);
