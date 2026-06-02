// FIXED by callHoist's unified mode-walker (transform/lowering/callHoist.ms): a fresh
// object literal passed INLINE as a call argument, where the callee stores it into a field,
// leaked — the value ended stuck at rc=1 (callee increfs a fresh rc=0 value; the caller never
// owned/destroyed it). This was the real Photon WS broadcast leak (~960 B/msg; processFrame →
// decisionDeliver({kind, data, closeCode})).
//
// Root cause was that callHoist enumerated per-statement-kind sub-positions and never reached
// call arguments (nor recognised interface-typed object literals — TypeKind.Struct + HasAsgn).
// The mode-walker hoists any fresh OWNED value in a non-consuming position (here: a borrow-param
// call argument) to `const $t = {...}`, which the analyzer then destroys at scope exit — exactly
// what binding to a const by hand did. Mirrors Nim's p(n, mode) + ensureDestruction.
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
