// Symptom: a method call that resolved to a body-less `this` signature incompatible with its implementation passed the checker; C failed at clang (`call to undeclared function`) and JS threw `ReferenceError`.
// Root cause: only a plain call validated an overload signature against its implementation and dispatched to it; a method call kept the signature as its target.
// Fix: a method call that picks a signature validates the signature set against its implementation and calls the implementation, as a plain call does.
import { compileToCWithStd } from "../helpers";

test "bug614: a method call through an incompatible signature is refused" {
	const result = compileToCWithStd(`
struct Account614 { address: uint64; }
function key(this a: Account614): uint64 { return a.address * 2; }
type Signer614 = distinct Account614;
function key(this s: Signer614): uint64;
const a: Account614 = { address: 21 };
const k = (a as Signer614).key();
`);
	const error = result.ok ? "" : result.error;
	assert error.indexOf("Overload signature for 'key' param 1 type 'Signer614' not assignable to implementation param type 'Account614'", 0) >= 0, error;
}

test "bug614: a method call through a compatible signature calls the implementation" {
	const result = compileToCWithStd(`
struct A614 { v: int32; }
struct B614 { w: int32; }
function show(this a: A614): int32;
function show(this b: B614): int32;
function show(this x: A614 | B614): int32 { return 1; }
const a: A614 = { v: 1 };
export const shown: int32 = a.show();
`);
	assert result.ok, result.ok ? "" : result.error;
}
