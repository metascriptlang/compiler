// @stdout: gt=true,false ge=true,false ne=true,false nested=false,true
// note: `!=`, `>` and `>=` derive from `==`, `<` and `<=` on a generic struct instance as they do on
// a plain struct: one type argument, two type arguments, and an instance nested in an instance.

struct Box<T> { v: T; }
struct Pair<K, V> { k: K; v: V; }

function `<`(a: Box<int32>, b: Box<int32>): boolean { return a.v < b.v; }
function `<=`(a: Box<int32>, b: Box<int32>): boolean { return a.v <= b.v; }

function main(): void {
	const one: Box<int32> = { v: 1 };
	const two: Box<int32> = { v: 2 };
	const p: Pair<int32, string> = { k: 1, v: "a" };
	const q: Pair<int32, string> = { k: 1, v: "b" };
	const inner: Box<Box<int32>> = { v: { v: 1 } };
	const same: Box<Box<int32>> = { v: { v: 1 } };
	const other: Box<Box<int32>> = { v: { v: 2 } };
	console.log(`gt=${two > one},${one > two} ge=${one >= one},${one >= two} ne=${p != q},${p != p} nested=${inner != same},${inner != other}`);
}

main();
