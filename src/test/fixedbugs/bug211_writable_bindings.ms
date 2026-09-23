// Symptom: after bug210, the writes that must stay legal: a `let` struct, a const whose type is a reference (object `type`, interface, class, `T[]`, `Ptr<T>`), and rebinding a parameter.
// Root cause: const is deep only through storage a declaration makes a value; a reference type's const fixes the binding alone (CK-91), and parameter rebinding is legal (CK-18).
// Fix: pinned on C and JS so a stricter relation cannot silently refuse them.

struct In211 { v: int32; }
struct S211 { a: int32; inner: In211; xs: int32[3]; }
type O211 = { a: int32 };
interface I211 { a: int32; }
class C211 { a: int32 = 0; }

function rebind211(p: int32): int32 {
	p = p + 1;
	return p;
}

test "bug211: a let struct is writable to the last field" {
	let s: S211 = { a: 1, inner: { v: 1 }, xs: [1, 2, 3] };
	s.a = 2;
	s.inner.v = 5;
	s.xs[1] = 6;
	s.a += 1;
	assert s.a == 3;
	assert s.inner.v == 5;
	assert s.xs[1] == 6;
}

test "bug211: a const object type, interface or class fixes the binding, not its fields" {
	const o: O211 = { a: 1 };
	o.a = 2;
	const i: I211 = { a: 1 };
	i.a = 3;
	const c = new C211();
	c.a = 4;
	assert o.a == 2;
	assert i.a == 3;
	assert c.a == 4;
}

test "bug211: a const T[] writes its elements" {
	const xs: int32[] = [1, 2];
	xs[0] = 9;
	assert xs[0] == 9;
}

test "bug211: a parameter can be rebound" {
	assert rebind211(1) == 2;
}

test "bug211: a const Ptr<T> writes its pointee" {
	const owner = new C211();
	const p: Ptr<C211> = owner;
	p.a = 7;
	assert owner.a == 7;
}
