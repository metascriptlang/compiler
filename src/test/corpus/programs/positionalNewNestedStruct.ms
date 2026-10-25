// @stdout: 0 0 0 0
// @stdout: n 2 x 3
// @stdout: l 0 0
// @stdout: 3 h 0 in 0
// note: `new` on a struct builds its object constructor: positional fields, the rest at their zero value, a nested struct field, a generic struct, a ternary arm, a loop and a class field initializer. Same output on C, JS and the Raiser.
struct Inner { a: int32; name: string; }
struct Outer { tag: string; inner: Inner; count: int32; }
struct Pair<T> { left: T; right: T; }
class Holder { slot: Outer = new Outer("h"); }

function make(flag: boolean): Outer {
	return flag ? new Outer("t", new Inner(7, "in")) : new Outer();
}

const z = new Outer();
const n = new Outer("n", new Inner(2, "x"), 3);
const p = new Pair<Inner>(new Inner(1, "l"));
let total = 0;
for (let i = 0; i < 3; i++) {
	let o = new Outer("loop");
	o.count += i as int32;
	total += o.count;
}
const h = new Holder();
const m = make(true);
const e = make(false);
console.log(`${z.tag.length} ${z.inner.a} ${z.inner.name.length} ${z.count}`);
console.log(`${n.tag} ${n.inner.a} ${n.inner.name} ${n.count}`);
console.log(`${p.left.name} ${p.right.a} ${p.right.name.length}`);
console.log(`${total} ${h.slot.tag} ${h.slot.inner.a} ${m.inner.name} ${e.tag.length}`);
