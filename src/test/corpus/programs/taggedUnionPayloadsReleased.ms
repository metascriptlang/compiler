// @stdout: made done
// @exit: 0
// note: a union that stores its tag and has no user hook releases the string and array its struct members hold when its cell goes, exactly once; a program end that finds one live, or releases one twice, fails.
struct A { n: int32; s: string; }
struct B { v: int32[]; t: string; }
type U = A | B;
function make(): string {
	const a: U = { n: 1, s: "x".repeat(3) } as A;
	const b: U = { v: [1, 2, 3], t: "y".repeat(3) } as B;
	return "made";
}
console.log(make() + " done");
