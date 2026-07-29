// @maxrss: 40
// @stdout: leak-callarg-object acc=
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED by the analyzer (inject.ms processObjectLiteral self-capture in Normal mode = Nim p()+ensureDestruction, injectdestructors.nim:889). A fresh interface object literal passed inline as a non-sink call argument, stored by the callee, leaked (value stuck at rc=1: callee increfs a fresh rc=0 value, caller never owned/destroyed it). processObjectLiteral processed the literal's FIELDS but never ensureDestruction'd the literal ITSELF; now it does in Normal mode (Consumed/SinkArg positions — binding RHS, sink param, ref field, return — skip it, so no double-free). The Phase-3 callHoist hoist could NOT fix this (never reached call args; crashed escape-heavy code) — this needed the Phase-4 analyzer. Was 431MB @ 2M, now flat ~2MB drc+orc. Paired with leak-callarg-escape (the multi-alias escape discriminator). See docs/NIM-REF.md §3.

// FIXED by the analyzer (inject.ms processObjectLiteral self-capture in Normal mode): a fresh
// object literal passed INLINE as a call argument, where the callee stores it into a field,
// leaked — the value ended stuck at rc=1 (callee increfs a fresh rc=0 value; the caller never
// owned/destroyed it). This was the real Photon WS broadcast leak (~960 B/msg; processFrame →
// decisionDeliver({kind, data, closeCode})).
//
// Root cause: processObjectLiteral processed the literal's FIELDS but never called
// ensureDestructionIfNeeded on the literal ITSELF, so a fresh ref/struct object constructor in a
// Normal (non-consumed) position was never captured for scope-exit destroy. The Phase-3 callHoist
// hoist could NOT fix it (enumerates per-statement-kind sub-positions, never reaches call args,
// and crashed escape-heavy code). The fix is Phase-4 ownership: processObjectLiteral now mirrors
// Nim's p()+ensureDestruction (injectdestructors.nim:889) — a fresh owned literal in Normal mode
// is captured to a temp destroyed at scope exit. Consumed/SinkArg positions (binding RHS, sink
// param, ref-constructor field, return) skip it, so no double-free. See docs/NIM-REF.md §3.
//
// Permanent regression guard: was 387MB @ 2M iters, now flat ~2MB.

interface Msg { data: number[]; }
interface Dec { m: Msg; }

function deliver(msg: Msg): Dec { return { m: msg }; }
function proc(src: Msg): Dec { return deliver({ data: src.data }); }

function main(): void {
	const orig: Msg = { data: [104, 105, 106, 107] };
	let acc = 0;
	for (let i = 0; i < 2000000; i = i + 1) {
		const d = proc(orig);
		acc = (acc + d.m.data.length) % 1000;
	}
	console.log(`leak-callarg-object acc=${acc}`);
}
main();
