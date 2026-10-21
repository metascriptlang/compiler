// An actor's spawn thunk cannot capture 'this', and a CALL cannot lend a mutable ref
//
// INVARIANT (ULTRALOCK T6, V0/V1): the actor is suspended while its spawn children run, so a
//   thunk borrows fields, never 'this' (PARALOCK S1/E61); a value crossing an actor boundary is
//   a value, a `move`, or a `const` reference the awaiting sender keeps alive (PARALOCK I21).
//
// WHAT IT CATCHES: the two refusals with no other pin: a bare 'this' captured by a spawn thunk
//   in an actor method, and an awaited actor CALL given a `let`-bound plain reference.
//
// RED MEANS: one of the two refusals stopped firing, or was retagged.
//
// GUARD-JS
// GUARD-CHECK-FAIL spawn thunk inside an actor method cannot capture 'this'
// GUARD-CHECK-FAIL actor methods only accept value types, `move`, or `const` references

import { stop, ExitReason } from "std/actor";

interface Plain { n: int32; }

actor Verbs {
	n: int32 = 1;
	weigh(p: Plain): int32 { return p.n; }
	capturesThis(): int32 {
		const h = spawn(() => { const self = this; return self.n; });
		return await h;
	}
}

async function mutableRefCall(): Promise<int32> {
	let p: Plain = { n: 2 };
	const v = new Verbs();
	const r = await v.weigh(p);
	stop(v.pid, ExitReason.Normal);
	return r;
}

console.log(await mutableRefCall());
