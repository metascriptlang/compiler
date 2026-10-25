// An actor may copy a scalar out of a lent CALL argument into its own state
//
// INVARIANT (ULTRALOCK V6, V5, V1): the lent parameter is a view; a scalar read out of it is a COPY
//   the actor may keep, the parameter may pass to a helper that only reads it, and a scalar read out of it may go into a
//   local alias of the actor's own container. A module function's result is kept when it is a
//   scalar, a string, or a fresh cell that reaches nothing lent.
//   Only the view itself is held back (actorKeptBorrowRejects.ms).
//
// RED MEANS: the kept-borrow refusal also catches a copy, so a receiver that reads a lent argument
//   into a scalar field no longer compiles, or the copy follows the caller's later write.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

class State { count: int32 = 0; name: string = "s"; }

function peek(s: State): int32 { return s.count - s.count; }

function nameOf(s: State): string { return s.name; }

function copyOf(s: State): State { const c = new State(); c.count = s.count; return c; }

actor Tally {
	seen: int32 = 0;
	counts: int32[] = [];
	name: string = "";
	copy: State | null = null;
	take(s: State): int32 { this.seen = s.count; const xs = this.counts; xs.push(s.count); this.name = nameOf(s); this.copy = copyOf(s); return this.seen + peek(s); }
	read(): int32 { return this.seen + this.counts[0] - 3 + this.copy!.count - 3 + this.name.length - 1; }
}

async function main(): Promise<void> {
	const w = new Tally();
	const st = new State();
	st.count = 3;
	const t = await w.take(st);
	st.count = 9;
	st.name = "changed";
	const kept = await w.read();
	stop(w.pid, ExitReason.Normal);
	if (t != 3 || kept != 3) throw new Error(`copy: t=${t} kept=${kept}`);
	console.log("GUARD-OK");
}

await main();
