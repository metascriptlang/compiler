// @stdout: 3 3 3 3 5 n 2 b
// @exit: 0
// note: a generic class's constructor calls generic functions over its own `T` (through a local alias, `this`, a `this` extension, two parameters, a nested generic `new`, and from another module). `new Box<int32>` must construct the instance class, whose constructor calls the instances; JS used to run the generic class's own constructor and threw "put__… is not defined".

import { Bag as LibBag } from "./bagLib";

class Bag<T> {
	items: T[];
	constructor(xs: T[]) { this.items = []; const self: Bag<T> = this; for (const x of xs) { put(self, x); } }
}
function put<T>(b: Bag<T>, x: T): void { b.items.push(x); }

class ThisBag<T> {
	items: T[];
	constructor(xs: T[]) { this.items = []; for (const x of xs) { putThis(this, x); } }
}
function putThis<T>(b: ThisBag<T>, x: T): void { b.items.push(x); }

class ExtBag<T> {
	items: T[];
	constructor(xs: T[]) { this.items = []; for (const x of xs) { this.putExt(x); } }
}
function putExt<T>(this b: ExtBag<T>, x: T): void { b.items.push(x); }

class Pair<K, V> {
	keys: K[];
	vals: V[];
	constructor(ks: K[], vs: V[]) {
		this.keys = []; this.vals = [];
		for (let i = 0; i < ks.length; i += 1) { add(this, ks[i], vs[i]); }
	}
}
function add<K, V>(p: Pair<K, V>, k: K, v: V): void { p.keys.push(k); p.vals.push(v); }

function identity<U>(u: U): U { return u; }
class Cell<T> {
	v: T;
	constructor(v: T) { this.v = identity(v); }
}

class Inner<T> { v: T; constructor(v: T) { this.v = v; } }
class Outer<T> {
	inner: Inner<T>;
	constructor(v: T) { this.inner = new Inner<T>(v); }
}

function main(): void {
	const lib = new LibBag<string>(["a", "b"]);
	console.log(
		new Bag<int32>([1, 2, 3]).items.length,
		new ThisBag<int32>([1, 2, 3]).items.length,
		new ExtBag<int32>([1, 2, 3]).items.length,
		new Pair<string, int32>(["a", "b", "c"], [1, 2, 3]).vals.length,
		new Cell<int32>(5).v,
		new Outer<string>("n").inner.v,
		lib.items.length,
		lib.items[1],
	);
}
main();
