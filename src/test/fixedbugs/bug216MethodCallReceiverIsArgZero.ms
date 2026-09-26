// Symptom: `x.f(a)` to an extension skipped the receiver when relating arguments, so `this ref x: T` could not be declared and a `Ptr<T>` reached a `this x: T` extension through a hidden deref that the free call `f(x)` refuses.
// Root cause: the method-form branches stripped the receiver before `relateCallArgs`; Nim's dotTransformation hands it to sigmatch as argument 0 (semexprs.nim:1670-1691).
// Fix: the receiver is related as argument 0 of the full signature; `this ref name: T` parses as a `Var<T>` receiver, and JS boxes it like any `ref` argument. Rule pinned: `v.f()` ≡ `f(v)`.
import { P216, get216 } from "./bug216Helper";

struct S216 { n: int32; }
type O216 = { n: int32 };
class C216 { n: int32 = 10; }
struct W216 { s: S216; }

function get(this x: S216): int32 { return x.n; }
function getO(this x: O216): int32 { return x.n; }
function getC(this x: C216): int32 { return x.n; }
function same<T>(this x: T): T { return x; }
function bump(this ref x: S216): void { x.n = x.n + 1; }
function bumpTwice(ref p: S216): void { p.bump(); p.bump(); }
function inc(this x: S216): S216 { return { n: x.n + 1 }; }
class D216 extends C216 { m: int32 = 1; }

test "bug216: a struct receiver reads the same as the free call" {
	const v: S216 = { n: 10 };
	assert v.get() == get(v);
	assert v.get() == 10;
}

test "bug216: object type, class and generic receivers read the same as the free call" {
	const o: O216 = { n: 11 };
	const c = new C216();
	const k: int32 = 12;
	assert o.getO() == getO(o) && o.getO() == 11;
	assert c.getC() == getC(c) && c.getC() == 10;
	assert k.same() == same(k) && k.same() == 12;
}

test "bug216: a Ref<T> receiver on a T extension behaves like the free call" {
	const r: Ref<S216> = { n: 13 };
	assert r.get() == get(r);
	assert r.get() == 13;
}

test "bug216: an imported extension and a chained call" {
	const p: P216 = { n: 14 };
	assert p.get216() == get216(p) && p.get216() == 14;
	const v: S216 = { n: 8 };
	assert v.inc().inc().get() == 10;
}

test "bug216: a subclass receiver reads the same as the free call" {
	const d = new D216();
	assert d.getC() == getC(d);
	assert d.getC() == 10;
}

test "bug216: a this ref receiver writes through a let, a field and an element" {
	let v: S216 = { n: 10 };
	v.bump();
	assert v.n == 11;
	let w: W216 = { s: { n: 20 } };
	w.s.bump();
	assert w.s.n == 21;
	let xs: S216[] = [{ n: 1 }, { n: 30 }];
	xs[1].bump();
	assert xs[1].n == 31;
}

test "bug216: a this ref receiver passes a ref parameter on" {
	let v: S216 = { n: 10 };
	bumpTwice(v);
	assert v.n == 12;
	bump(v);
	assert v.n == 13;
}
