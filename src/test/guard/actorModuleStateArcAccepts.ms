// An Arc module const lent to an actor call and kept by an actor field: the C-only neighbour of
// actorModuleStateReachRefused.ms (Arc<T> has no JS).
//
// INVARIANT (ULTRALOCK V0, V7): an Arc is a SHARE that crosses by its atomic count, so the module-state
//   reach check does not refuse it.
//
// RED MEANS: the module-state reach check refuses an Arc<T> module const.

struct Payload { buf: string; n: int32; }

const SHARED_ARC: Arc<Payload> = new Arc({ buf: "kept", n: 4 });

actor Reader {
	held: Arc<Payload> = SHARED_ARC;
	shared(h: Arc<Payload>): int32 { return h.n + this.held.n; }
}

async function main(): Promise<void> {
	const r = new Reader();
	const a = SHARED_ARC;
	const n = await r.shared(a);
	if (n != 8) throw new Error(`arc: n=${n}`);
	console.log("GUARD-OK");
}

await main();
