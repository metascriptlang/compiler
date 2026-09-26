// Symptom: inside a generic class constructor `this` was refused where the class instance is expected: `putI(this, x)` against `Bag<int32>` failed with `got Bag_…__int32, expected Bag`.
// Root cause: the constructor instance was re-checked with `this` typed as a fresh struct named after the mangled class, a second type for `Bag<int32>` beside the instance `new Bag<int32>()` gets.
// Fix: the re-checked constructor types `this` as that same instance, as Nim gives every `Bag[int]` one cached tyGenericInst.

class Bag219<T> {
	items: T[];
	constructor(xs: T[]) {
		this.items = [];
		for (const x of xs) { this.add(x); }
	}
	add(x: T): void { this.items.push(x); }
	me(): Bag219<T> { return this; }
}

class IntBag219<T> {
	items: int32[];
	constructor(xs: int32[]) {
		this.items = [];
		for (const x of xs) { putInt219(this, x); }
		const self: IntBag219<int32> = this;
		putInt219(self, 100);
	}
}

function putInt219(b: IntBag219<int32>, x: int32): void { b.items.push(x); }

class Pair219<K, V> {
	ks: K[];
	vs: V[];
	constructor(k: K, v: V) {
		this.ks = [];
		this.vs = [];
		putPair219(this, 1, "a");
		this.ks.push(k);
		this.vs.push(v);
	}
}

function putPair219(p: Pair219<int32, string>, k: int32, v: string): void { p.ks.push(k); p.vs.push(v); }

test "bug219: this in a generic constructor calls the class's own method" {
	const b = new Bag219<int32>([1, 2, 3]);
	assert b.items.length == 3;
	assert b.me().items.length == 3;
}

test "bug219: this in a generic constructor is the concrete instance type" {
	const b = new IntBag219<int32>([1, 2]);
	assert b.items.length == 3;
	assert b.items[2] == 100;
}

test "bug219: this in a two-parameter generic constructor is its instance" {
	const p = new Pair219<int32, string>(7, "z");
	assert p.ks.length == 2;
	assert p.vs[1] == "z";
}
