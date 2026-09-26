// Symptom: `put(this, x)` inside a generic class constructor, against `put<T>(b: Bag<T>, x: T)`, failed to type check: `got Bag_…__int32, expected Bag`.
// Root cause: the re-checked constructor typed `this` as a struct unrelated to `Bag<T>`, so unification could not bind `T` from it.
// Fix: `this` is the class instance `Bag<int32>`, which binds `T` like any `Bag<int32>` argument.
import { compileToCWithStd } from "../helpers";

function ctorError220(src: string): string {
	const result = compileToCWithStd(src);
	return result.ok ? "" : result.error;
}

test "bug220: this binds T of a generic free function" {
	const error = ctorError220(`
class Bag<T> {
	items: T[];
	constructor(xs: T[]) { this.items = []; for (const x of xs) { put(this, x); } }
}
function put<T>(b: Bag<T>, x: T): void { b.items.push(x); }
console.log(new Bag<int32>([1, 2, 3]).items.length);
`);
	assert error == "", error;
}

test "bug220: this binds two type parameters" {
	const error = ctorError220(`
class Pair<K, V> {
	ks: K[];
	vs: V[];
	constructor(k: K, v: V) { this.ks = []; this.vs = []; putP(this, k, v); }
}
function putP<K, V>(p: Pair<K, V>, k: K, v: V): void { p.ks.push(k); p.vs.push(v); }
console.log(new Pair<int32, string>(1, "a").ks.length);
`);
	assert error == "", error;
}

test "bug220: this as a generic extension receiver" {
	const error = ctorError220(`
class Bag<T> {
	items: T[];
	constructor(xs: T[]) { this.items = []; for (const x of xs) { this.put(x); } }
}
function put<T>(this b: Bag<T>, x: T): void { b.items.push(x); }
console.log(new Bag<int32>([1, 2, 3]).items.length);
`);
	assert error == "", error;
}
