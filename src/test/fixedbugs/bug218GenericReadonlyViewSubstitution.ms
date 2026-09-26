// Symptom: `f<T>(b: Readonly<Box<T>>)` refused a `Readonly<Box<int32>>` argument ("got Readonly<Box>, expected Box"), and so did the method form once its receiver was related.
// Root cause: substitution rebuilt a `Ref` formal with `createRef`, dropping the readonly view (`rebuildRefLike`).
// Fix: `rebuildRefLike` keeps the view on the rebuilt `Ref`.

class Box218<T> { v: T; constructor(v: T) { this.v = v; } }

function peekFree218<T>(b: Readonly<Box218<T>>): T { return b.v; }
function peek218<T>(this b: Readonly<Box218<T>>): T { return b.v; }
function viaView218(b: Readonly<Box218<int32>>): int32 { return peekFree218(b) + b.peek218(); }

test "bug218: a generic Readonly formal accepts a view, free and method form" {
	const b = new Box218<int32>(5);
	assert viaView218(b) == 10;
	assert peekFree218(b) == 5;
	assert b.peek218() == 5;
}

test "bug218: a generic Readonly formal binds a string payload" {
	const b = new Box218<string>("x");
	assert peekFree218(b) == "x";
	assert b.peek218() == "x";
}
