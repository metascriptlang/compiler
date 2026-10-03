// Each closure environment is a type of its own: same-named functions with a same-named
// captured binding in different modules must not share one set of lifecycle ops.
//
// RED MEANS: a later module's environment found the first module's ops registered under
// the shared spelling and shipped a TypeInfo with destroyFn = NULL, so the `Inner` it holds
// leaks (observed as `LEDGER Inner alloc=36 destroy=12`).
//
// GUARD-BALANCE Inner
// GUARD-JS

import { work as workA, outer as outerA, nested as nestedA } from "./fixtures/closureEnv/a";
import { work as workB, outer as outerB, nested as nestedB } from "./fixtures/closureEnv/b";
import { work as workC, outer as outerC, nested as nestedC } from "./fixtures/closureEnv/c";

function main(): void {
	let t = 0;
	for (let i = 0; i < 3; i += 1) {
		t += workA() + outerA() + nestedA();
		t += workB() + outerB() + nestedB();
		t += workC() + outerC() + nestedC();
	}
	console.log("T=" + t.toString());
}

main();
console.log("GUARD-OK");
