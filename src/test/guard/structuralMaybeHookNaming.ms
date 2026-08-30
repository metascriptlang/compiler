// A compiler-synthesized structural type (Maybe_<payload>, msTuple_, msAnon_,
// msUnion_) is ONE globally cached object shared by every module, so the symbol
// it happens to carry is whichever module created it first — not a declaring
// owner. Module-qualifying such a name makes the C spelling depend on WHEN it
// is asked for: reached through the alias it resolves qualified, reached
// through the inline union it resolves bare, and a single TU then forward
// declares <T>Eq against one spelling and defines it against the other.
//
// RED MEANS: the build dies at
//   error: conflicting types for 'Maybe_p34_unionnumberstring20Eq'
// where the declaration names Maybe_… and the definition names
// Maybe_…__Z<module>. The carve-out lives in mangledTypeName
// (codegen/c/names.ms) beside the "$" and monomorphized "__" ones.

import { exit } from "std/process";
import { Own, SV, setField } from "./fixtures/sharedMaybeCarrier";

function bind(o: Own, name: string, get: () => SV): number {
	let prev: SV = null;
	let bound = false;
	let writes = 0;
	const run = () => {
		const v = get();
		if (bound && v === prev) { return; }
		bound = true;
		prev = v;
		writes += 1;
		setField(o, name, v);
	};
	run();
	run();
	return writes;
}

function main(): void {
	const o: Own = { w: null, h: null };
	const writes = bind(o, "w", () => 7);
	if (writes !== 1) {
		console.log("FAIL: carrier equality did not dedup the second write, writes=" + writes.toString());
		exit(1);
	}
	if (o.w === null) {
		console.log("FAIL: field not written through the shared carrier");
		exit(1);
	}
	console.log("GUARD-OK");
}
main();
