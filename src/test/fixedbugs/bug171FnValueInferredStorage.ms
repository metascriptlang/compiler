// bug171 — a function value whose storage type was inferred from a named function
// Symptom: a named function stored through an inferred object field, array element, return, generic binding or
//          ternary (`const o = { f: dbl }`, `[dbl]`, `function pick() { return dbl; }`, `() => dbl`, `id(dbl)`,
//          `flag ? dbl : tri`) died in clang (`assigning to 'msClosure' from incompatible type 'double (double)'`,
//          `called object type 'msClosure' is not a function`); an explicit function annotation ran. JS ran.
// Root cause: the function-to-closure thunk was keyed on the node shape (an Identifier naming a function), and a
//             storage type inferred from a named function kept the non-closure calling convention while every C
//             slot holding a function value is an msClosure.
// Fix: the thunk is keyed on the types (closure slot, non-closure value), and a storage type inferred from a
//      function value takes the closure calling convention at every inference site: variable, object-literal
//      field, array element, branch join, inferred return and generic binding.

function double171(x: number): number { return x * 2; }
function triple171(x: number): number { return x * 3; }
function id171<T>(x: T): T { return x; }
function only171() { return double171; }
function pick171(flag: boolean) {
	if (flag) { return double171; }
	return triple171;
}
function takePlain171(f: (x: number) => number): number { return f(5); }

test "bug171: a named function in an inferred object field and array element" {
	const o = { f: double171 };
	assert o.f(5) === 10;
	assert takePlain171(o.f) === 10;
	const one = [triple171];
	assert one[0](5) === 15;
	const two = [double171, triple171];
	assert takePlain171(two[1]) === 15;
}

test "bug171: a named function through an inferred return" {
	assert only171()(5) === 10;
	assert takePlain171(only171()) === 10;
	assert pick171(true)(5) === 10;
	assert pick171(false)(5) === 15;
	const mk = () => triple171;
	assert mk()(5) === 15;
}

test "bug171: a named function through a generic binding and an inferred ternary" {
	const g = id171(double171);
	assert g(5) === 10;
	const flag = takePlain171(double171) > 0;
	const t = flag ? triple171 : double171;
	assert t(5) === 15;
}

test "bug171: an inferred function local still reassigns" {
	let f = double171;
	assert f(5) === 10;
	f = triple171;
	assert f(5) === 15;
}
