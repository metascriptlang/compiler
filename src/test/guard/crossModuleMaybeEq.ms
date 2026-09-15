// A generated hook's forward declaration is synthesized from its NAME, while its
// definition is emitted from its TYPE. They agree only while the operand happens
// to sit under the pointer-introduction threshold. Maybe<number|string> is 32
// bytes — the definition takes it by pointer, and a consumer that only ever sees
// the synthesized prototype must take it by pointer too.
//
// RED MEANS: the build dies at
//   error: passing 'Maybe_…*' to parameter of incompatible type 'Maybe_…'
// or links a caller that pushes a pointer against a callee that pops a struct.

import { exit } from "std/process";
import { WV, sameValue } from "./fixtures/wideMaybeEq";

function main(): void {
	const a: WV = 7;
	const b: WV = "seven";
	const c: WV = null;
	if (!sameValue(a, a)) { console.log("FAIL: equal values compared unequal"); exit(1); }
	if (sameValue(a, b)) { console.log("FAIL: different values compared equal"); exit(1); }
	if (sameValue(a, c)) { console.log("FAIL: value compared equal to null"); exit(1); }
	let local: WV = b;
	if (!(local == b)) { console.log("FAIL: local compare disagreed"); exit(1); }
	local = c;
	if (local == b) { console.log("FAIL: reassigned local still compared equal"); exit(1); }
	console.log("GUARD-OK cross-module maybe eq");
}

main();
