// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (destroyed 0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: the union and its destroy hook are declared in another module; the hook still binds to the union's declaring symbol, so a value built and dropped here runs it once.
import { A, U, destroyedCount } from "./u";

function make(): void {
	const u: U = { n: 1 } as A;
	console.log("made");
}

make();
console.log("destroyed " + destroyedCount().toString());
