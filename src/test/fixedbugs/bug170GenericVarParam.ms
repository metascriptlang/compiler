// bug170 — a generic parameter under ref, out, Borrow or Cursor never bound T
//
// Symptom:    `put(box, 5)` against `put<T>(ref box: Box<T>, v: T)` failed with `cannot instantiate: 'T'`, and so
//             did the explicit `put<int32>(box, 5)`, a bare `ref x: T`, `out box: Box<T>`, `b: Borrow<T>` and
//             `c: Cursor<T>`, on C and JS. A value parameter `Box<T>` bound T.
// Root cause: checker/types.ms — unifyTypeInner had no arm for a Var, Borrow or Cursor formal, so none produced a
//             binding; substituteTypeInner and substituteAllParams ended in `_ => t` with no Var or Cursor arm,
//             so an explicit binding never reached the type inside the wrapper.
// Fix:        unify the wrapper's base with the argument (base with base when the argument has the same wrapper),
//             and rebuild Var and Cursor around the substituted base.

struct Box170<T> { value: T; }
class Pet170 { hunger: int32 = 3; }

function put170<T>(ref box: Box170<T>, v: T): void { box.value = v; }
function peek170<T>(ref box: Box170<T>): T { return box.value; }
function set170<T>(ref x: T, v: T): void { x = v; }
function fill170<T>(out box: Box170<T>, v: T): void { box = { value: v }; }
function seen170<T>(b: Borrow<T>): boolean { return true; }
function isSet170<T>(c: Cursor<T>): boolean { return c != null; }

test "bug170: a generic ref parameter binds T from the argument" {
	let box: Box170<int32> = { value: 1 };
	put170(box, 5);
	assert box.value == 5;
	assert peek170(box) == 5;
	let label: Box170<string> = { value: "a" };
	put170(label, "b");
	assert label.value == "b";
}

test "bug170: an explicit type argument substitutes inside a ref parameter" {
	let box: Box170<int32> = { value: 1 };
	put170<int32>(box, 7);
	assert box.value == 7;
}

test "bug170: a bare generic ref parameter writes through" {
	let n: int32 = 1;
	set170(n, 5);
	assert n == 5;
}

test "bug170: a generic out parameter binds T" {
	let box: Box170<int32> = { value: 1 };
	fill170(box, 9);
	assert box.value == 9;
}

test "bug170: generic Borrow and Cursor parameters bind T" {
	const pet = new Pet170();
	const borrowed: Borrow<Pet170> = pet;
	const cursor: Cursor<Pet170> = pet;
	assert seen170(borrowed);
	assert seen170(pet);
	assert isSet170(cursor);
	assert isSet170(pet);
}
