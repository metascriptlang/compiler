// A view widened into a union of views stays a view
//
// INVARIANT (ULTRALOCK views): `Readonly<A | B | null>` is `Readonly<A> | Readonly<B> | null`, so a view
//   reaches a union only through a read-only member; a union with a mutable member never takes it.
//
// RED MEANS: a read-only view, or a nullable or union of views, fits a union holding the mutable class.
//
// GUARD-CHECK-FAIL a read-only view never converts back to the mutable type

class A { n: int32 = 1; }
class B { n: int32 = 2; }

function viewIntoMutableUnion(x: Readonly<A>): A | B | null {
	return x; // GUARD-REFUSED
}
function nullableViewIntoMutableUnion(x: Readonly<A> | null): A | B | null {
	return x; // GUARD-REFUSED
}
function distributedIntoMutableUnion(x: Readonly<A | B | null>): A | B | null {
	return x; // GUARD-REFUSED
}
function viewIntoMutable(x: Readonly<A>): A {
	return x; // GUARD-REFUSED
}
