// @stdout: 6 s 2
// @stdout: 1 2 k 3
// @stdout: a,b 1
class Box<T> {
	v: T;
	constructor(v: T) {
		this.v = v;
	}
}
class Bag<T> {
	items: T[] = [];
	constructor(items: T[] = []) {
		this.items = items;
	}
}
class Dict<K, V> {
	keys: K[] = [];
	vals: V[] = [];
	constructor(pairs: Array<[K, V]> = []) {
		for (const p of pairs) {
			this.keys.push(p[0]);
			this.vals.push(p[1]);
		}
	}
}
function second<K, V>(p: [K, V]): V {
	return p[1];
}
function firsts<K, V>(ps: Array<[K, V]>): K[] {
	return ps.map((p) => p[0]);
}
const a = new Box(5);
const b = new Box("s");
const many = new Box([1, 2]);
console.log(a.v + 1, b.v, many.v.length);
const d = new Dict([["k", 1]]);
const e = new Dict<string, int32>([["j", 2]]);
const bag = new Bag([1, 2, 2]);
console.log(d.vals[0], second(["z", e.vals[0]]), d.keys[0], bag.items.length);
console.log(firsts([["a", 1], ["b", 2]]).join(","), second(["x", 1]));
