// A namespace member naming a function reaches every closure slot as a thunk
//
// INVARIANT: a value of a non-closure function
//   type meeting a closure-typed slot becomes (fn, nil), decided by the two types, whatever expression
//   spells the function — here `L.tri` from `import * as L`, which stays a MemberExpr through codegen.
//
// WHAT IT CATCHES: the thunk, or the analyzer's "a function symbol is not a location" exemption, keyed
//   on an Identifier node, so a raw C function is assigned to an msClosure (clang `assigning to
//   'msClosure' from incompatible type`) or copied through msClosureCopy.
//
// RED MEANS: build error, or exit != 0.

import { exit } from "std/process";
import * as L from "./fixtures/namespaceFnValueLib";

function takePlain(f: (x: number) => number): number { return f(2); }
function takeMaybe(f: ((x: number) => number) | null): number {
	if (f === null) return -1;
	return f(2);
}

function main(): void {
	const bare: (x: number) => number = L.tri;
	const inferred = L.tri;
	const maybe: ((x: number) => number) | null = L.tri;
	const u: ((x: number) => number) | string = L.tri;
	let viaUnion: number = -1;
	if (typeof u === "function") viaUnion = u(2);
	const got: number[] = [bare(2), inferred(2), takePlain(L.tri), takeMaybe(L.tri), takeMaybe(maybe), viaUnion];
	let line = "";
	for (const g of got) line = line + g.toString() + " ";
	console.log(line);
	for (const g of got) {
		if (g !== 6) { console.log("FAIL: namespace function value"); exit(1); }
	}
	console.log("GUARD-OK namespace function value");
}

main();
