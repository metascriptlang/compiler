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
