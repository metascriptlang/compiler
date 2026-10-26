// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: hook fd:0
// @stdout: hook inner:7
// note: a module imported only for its types is not evaluated, unless a value of such a type runs a lifecycle hook, which is code of the hook's module; here each hook lives two imports away, behind a struct that holds the hooked struct or distinct type, and prints module state set while its module is evaluated.
import { Outer, Wrap } from "./holder";

function scope(): void {
	const o: Outer = { x: { v: 7 } };
	const w: Wrap = {};
	console.log("made " + o.x.v.toString());
}

scope();
