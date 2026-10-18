// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (destroyed 0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a user destroy hook declared for a named union binds to the union's declaring symbol; a value of the union going out of scope runs it exactly once.
struct A { n: int32; }
struct B { s: string; }
type U = A | B;

let destroyed: int32 = 0;

function onDestroy(this u: U): void { destroyed += 1; }

function make(): void {
	const u: U = { n: 1 } as A;
	console.log("made");
}

make();
console.log("destroyed " + destroyed.toString());
