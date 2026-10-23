// An actor does not keep an argument an awaited CALL only lends it
//
// INVARIANT (ULTRALOCK V6, V5): a CALL carrying a BORROW lends the argument until the reply; the
//   receiving parameter is a view that never goes into the actor's state or module state.
//
// WHAT IT CATCHES: a receiver that keeps the lent parameter: in its own field, in a Map it owns,
//   in a module-level binding, through a local alias of the parameter, through a module
//   function that keeps what it is handed, in a stored closure that captures it, and pushed into
//   a local alias of the actor's own container, and through what a module function returns from it
//   (directly, through a local, or a field read off the result). A call to the actor's own method is a CALL of its own,
//   judged at that call site.
//
// RED MEANS: the actor can keep an uncounted pointer into the caller's graph past the reply, so the
//   caller frees what the actor still reads.
//
// The copy neighbour is pinned by actorKeptBorrowCopyRuns.ms, which must build and run.
//
// GUARD-JS
// GUARD-CHECK-FAIL actor method 'take' keeps its parameter 's': it stores it in 'this.keep'
// GUARD-CHECK-FAIL actor method 'file' keeps its parameter 's': it passes it to 'this.byName.set'
// GUARD-CHECK-FAIL actor method 'note' keeps its parameter 's': it stores it in 'last'
// GUARD-CHECK-FAIL actor method 'alias' keeps its parameter 's': it stores it in 'this.keep'
// GUARD-CHECK-FAIL actor method 'relay' keeps its parameter 's': it passes it to 'park'
// GUARD-CHECK-FAIL actor method 'hook' keeps its parameter 's': it stores it in 'this.cb'
// GUARD-CHECK-FAIL actor method 'stack' keeps its parameter 's': it passes it to 'xs.push'
// GUARD-CHECK-FAIL actor method 'pick' keeps its parameter 's': it stores it in 'this.keep'
// GUARD-CHECK-FAIL actor method 'pickLocal' keeps its parameter 's': it stores it in 'this.keep'
// GUARD-CHECK-FAIL actor method 'pickField' keeps its parameter 's': it stores it in 'this.keep'
// GUARD-CHECK-FAIL send ownership with `move st`
// GUARD-CHECK-FAIL (PARALOCK I21)

import { stop, ExitReason } from "std/actor";

class State { count: int32 = 0; next: State | null = null; }

let last: State | null = null;

function park(s: State): void { last = s; }

function same(s: State): State { return s; }

function nextOf(s: State): State | null { const n = s.next; return n; }

actor Keeper {
	keep: State | null = null;
	byName: Map<string, State> = new Map<string, State>();
	list: State[] = [];
	cb: (() => int32) | null = null;
	take(s: State): int32 { this.keep = s; return s.count; }
	file(s: State): int32 { this.byName.set("k", s); return s.count; }
	note(s: State): int32 { last = s; return s.count; }
	alias(s: State): int32 { const held = s; this.keep = held; return s.count; }
	relay(s: State): int32 { park(s); return s.count; }
	hook(s: State): int32 { this.cb = () => s.count; return s.count; }
	stack(s: State): int32 { const xs = this.list; xs.push(s); return s.count; }
	pick(s: State): int32 { this.keep = nextOf(s); return s.count; }
	pickLocal(s: State): int32 { const n = same(s); this.keep = n; return s.count; }
	pickField(s: State): int32 { this.keep = same(s).next; return s.count; }
}

async function main(): Promise<void> {
	const w = new Keeper();
	const st = new State();
	st.count = 3;
	const t = await w.take(st) + await w.file(st) + await w.note(st) + await w.alias(st) + await w.relay(st) + await w.hook(st) + await w.stack(st) + await w.pick(st) + await w.pickLocal(st) + await w.pickField(st);
	stop(w.pid, ExitReason.Normal);
	console.log(`t=${t}`);
}

await main();
