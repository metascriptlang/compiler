// bug128 — static method on a generic class has no monomorphized body
//
// Symptom:    `Box.make(5)` on `class Box<T>` passes the checker but the C
//             build fails with "call to undeclared function 'Box_make__…_u0'"
//             — the call site is emitted unmonomorphized while no body is
//             ever emitted under any name.
// Root cause: src/checker/collectPass.ms — a static method carries no
//             receiver, so the class's type params never reached its
//             methodFlags; every mono gate (call-site instantiation,
//             template skip, codegen skip) keys on `gen:` in the method's
//             own flags and dropped it.
// Fix:        collectClassMethod stamps `gen:<classGenerics>` onto a static
//             method's methodFlags when the owning class is generic, so the
//             method owns its generic params exactly like a generic free
//             function.

class Box<T> {
	v: T;
	static make(x: T): Box<T> {
		const b = new Box<T>();
		b.v = x;
		return b;
	}
}

test "bug128: explicit type arg instantiates static of generic class" {
	const a = Box.make<int32>(5);
	assert a.v === 5;
}

test "bug128: annotated destination instantiates static of generic class" {
	const b: Box<int32> = Box.make(7);
	assert b.v === 7;
}

test "bug128: per-type instantiations coexist" {
	const c = Box.make<string>("hey");
	assert c.v === "hey";
	assert c.v.length === 3;
}
