// @ledger-slack(msRefArrayRefCell): 1
// @maxrss: 40
// @stdout: leak-callarg-escape acc=
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED with leak-callarg-object (inject.ms processObjectLiteral self-capture). Escape-heavy variant: a fresh interface object literal passed inline as a call arg is stored by the callee into a returned Box, then pushed into a persistent hub.subs list drained every 8 iters — so the value OUTLIVES the statement that created it (the multi-alias broadcast shape the Phase-3 callHoist hoist crashed on with over-free/SIGSEGV). This case is the PERMANENT discriminator proving the Phase-4 fix is over-free-SAFE on escaping values: the push-incref keeps the value alive until drain frees it, so the caller's scope-exit destroy of the captured temp is one balanced decref — NOT a premature free. Was 370MB @ 2M, now flat ~2MB drc+orc. If this ever SIGSEGVs, a fix made the literal capture too eager (destroying a value still aliased downstream).

// leak-callarg-escape — ESCAPE-HEAVY variant of leak-callarg-object.
//
// Same root leak (a fresh interface object literal passed INLINE as a call argument, stored by
// the callee — ends stuck at rc=1/rc=0, never destroyed by the caller) but here the stored value
// ESCAPES the caller's scope: `wrap({...})` puts the fresh Evt into the returned Box, and the Box
// is pushed into a persistent `hub.subs` list drained only every 8 iterations. The published value
// therefore OUTLIVES the statement that created it.
//
// This is the multi-alias broadcast shape that the Phase-3 callHoist hoist crashed on (temp scope
// != value lifetime). It is the discriminator between three outcomes:
//   - no fix             → LEAK (fresh literal never captured; ~hundreds of MB at 2M iters)
//   - over-eager fix     → SIGSEGV/over-free (caller temp destroyed while value still live in subs)
//   - correct Phase-4 fix → flat, exit 0 (processObjectLiteral self-captures in Normal mode =
//                            Nim p() + ensureDestruction; push-incref keeps the value alive until
//                            drain frees it — one balanced decref pair)

interface Evt { data: number[]; }
interface Box { e: Evt; }
interface Hub { subs: Box[]; }

function wrap(ev: Evt): Box { return { e: ev }; }

function main(): void {
	const hub: Hub = { subs: [] };
	let acc = 0;
	for (let i = 0; i < 2000000; i = i + 1) {
		const b = wrap({ data: [i % 7, i % 5, i % 3] });
		hub.subs.push(b);
		if (i % 8 === 7) {
			for (const s of hub.subs) { acc = (acc + s.e.data.length) % 100; }
			hub.subs = [];
		}
	}
	for (const s of hub.subs) { acc = (acc + s.e.data.length) % 100; }
	console.log(`leak-callarg-escape acc=${acc}`);
}
main();
