// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: a:xxx,b:3 destroyed 2
// @exit: 0
// note: a user destroy hook declared for a union of discriminated structs runs once per value going out of scope, the discriminant and the members still read through the union, and the string and array a member holds are released after the hook.
struct A { kind: "a"; s: string; }
struct B { kind: "b"; v: int32[]; }
type U = A | B;
let destroyed: int32 = 0;
function onDestroy(this u: U): void { destroyed += 1; }
function describe(u: U): string {
	if (u.kind == "a") return "a:" + u.s;
	return "b:" + u.v.length.toString();
}
function make(): string {
	const a: U = { kind: "a", s: "x".repeat(3) } as A;
	const b: U = { kind: "b", v: [1, 2, 3] } as B;
	return describe(a) + "," + describe(b);
}
const text = make();
console.log(text + " destroyed " + destroyed.toString());
