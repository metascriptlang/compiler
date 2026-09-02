// bug117 — Maybe-carried `T | null` lost its carrier after an if/else join
//
// Symptom:    `const a = pick(); if (a !== null) {..} else {..}; a !== null ? x : y`
//             with a: number | null emitted `a_.value != MS_NIL` for the SECOND
//             null-check (clang: invalid operands 'double' and 'void *').
//             Corpus 010-nullable carried @xfail(c/orc/danger/san) for it.
// Root cause: flow.ms getTypeAtBranchLabel joined the narrowed halves
//             (`number` on the true edge, `null` on the false edge) with
//             createUnion → a fresh `null | number` Union, not the declared
//             Maybe struct. Downstream nothing recognised that spelling:
//             materializeMaybeReads wrapped the read in `.value` (declared
//             symbol IS Maybe) while operatorLower saw a non-Maybe nodeType
//             and kept a raw pointer compare.
// Fix:        joinNarrowedTypes returns the declared Maybe carrier when the
//             joined members are exactly {inner, null} (flow.ms) — re-joining
//             a declared type's constituents yields the declared type.

import { compileToC } from "../helpers";

const b117src = `
function pick(on: boolean): number | null {
	if (on) { return 1; }
	return null;
}
function b117(): void {
	const a = pick(true);
	if (a !== null) { console.log("y"); } else { console.log("n"); }
	console.log(a !== null ? "t" : "f");
	const s = pick(false);
	if (s === null) { console.log("n"); } else { console.log("y"); }
	if (s !== null) { console.log("z"); }
}
b117();
`;

test "bug117: null-check after an if/else join stays a present-check" {
	const out = compileToC(b117src);
	assert out.ok;
	if (out.ok) {
		assert !out.value.contains(".value != MS_NIL");
		assert !out.value.contains(".value == MS_NIL");
		assert out.value.contains(".present");
	}
}
