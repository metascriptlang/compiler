// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (destroyed 0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a distinct type and its destroy hook are declared in another module; a value built there and dropped here runs the hook once.
import { Handle, mk, destroyedCount } from "./d";

function make(): void {
	const h: Handle = mk();
	console.log("made");
}

make();
console.log("destroyed " + destroyedCount().toString());
