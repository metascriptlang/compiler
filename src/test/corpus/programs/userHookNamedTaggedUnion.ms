// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: made destroyed 2 text hi
// @exit: 0
// note: a user destroy hook declared for a named union that stores its tag (number literals beside a string) runs once per value going out of scope, for a scalar member and for a string member, and the value's cell is released after it.
type Mixed = 1 | 2 | string;
let destroyed: int32 = 0;
function onDestroy(this u: Mixed): void { destroyed += 1; }
function make(): string {
	const m: Mixed = "h" + "i";
	const n: Mixed = 2;
	return "made";
}
const text = make();
const kept: Mixed = "hi";
console.log(text + " destroyed " + destroyed.toString() + " text " + (kept as string));
