// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): a union of struct members told apart by a shared discriminant is the member's own cell, which has no class of the union to carry its destroy hook
// @stdout: made destroyed 2
// @exit: 0
// note: a user destroy hook declared for a discriminated union of structs runs once per value going out of scope, and the string and array a member holds are released after it.
struct A { kind: "a"; s: string; }
struct B { kind: "b"; v: int32[]; }
type U = A | B;
let destroyed: int32 = 0;
function onDestroy(this u: U): void { destroyed += 1; }
function make(): string {
	const a: U = { kind: "a", s: "x".repeat(3) } as A;
	const b: U = { kind: "b", v: [1, 2, 3] } as B;
	return "made";
}
const text = make();
console.log(text + " destroyed " + destroyed.toString());
