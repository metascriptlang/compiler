// Two modules declaring the same type name each need their OWN lifecycle hooks.
// Nim gets this for free: `produceSym` owns a hook by `typ.owner`
// (liftdestructors.nim) and the op table is keyed by `t.itemId`
// (modulegraphs.nim setAttachedOp), so two same-named types in different
// modules can never share an entry. MetaScript keys those registries by NAME —
// an intentional divergence (structural typing has no canonical ItemId,
// NIM-REF row 72) that only holds while the name IS the emitted C name.
//
// RED MEANS: the second module's `Item` found the first module's hooks already
// registered under the bare name, skipped its own, and its TypeInfo shipped
// with destroyFn = NULL — every `Inner` it owns leaks, silently, build green.
// Observed as `LEDGER Inner alloc=6 destroy=3`.
//
// GUARD-BALANCE Inner

import { makeA } from "./fixtures/sameNameHookA";
import { makeB } from "./fixtures/sameNameHookB";

function main(): void {
	let t = 0;
	for (let i = 0; i < 3; i += 1) {
		t += makeA();
		t += makeB();
	}
	console.log("T=" + t.toString());
}

main();
console.log("GUARD-OK");
