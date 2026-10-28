// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: made destroyed 2
// @exit: 0
// note: a user destroy hook on a union that stores its tag runs once per value, and the string and array its struct members hold are released exactly once after it; a program end that finds one live, or releases one twice, fails.
struct A { n: int32; s: string; }
struct B { v: int32[]; t: string; }
type U = A | B;
let destroyed: int32 = 0;
function onDestroy(this u: U): void { destroyed += 1; }
function make(): string {
	const a: U = { n: 1, s: "x".repeat(3) } as A;
	const b: U = { v: [1, 2, 3], t: "y".repeat(3) } as B;
	return "made";
}
const text = make();
console.log(text + " destroyed " + destroyed.toString());
