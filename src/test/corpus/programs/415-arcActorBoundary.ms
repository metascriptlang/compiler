// @maxrss: 20
// @stdout: arc-actor-boundary send=2100000 call=1500000
// @serial
// @skip-js: Arc<T> is a C-backend atomic-rc box; no js binding
// note: the SHARE verb at the actor boundary (PARALOCK Amendment I / I21). Both invocation classes are exercised on ONE shape: a fire-and-forget SEND (void method, sender never parks) and an awaited CALL (sender parked, mechanically a BORROW). In both the sender drops its LAST reference immediately — the handle dies at the end of the loop iteration while the message may still be in flight — and a fresh Arc is allocated every round so a freed cell is handed straight back to the next allocation. That is the exact shape that was a deterministic use-after-free before this amendment (msMsgSetPtr stored the raw pointer with no incref; the accumulated counter read the reuser's field, rounds x junk.n instead of rounds x 7). It is sound now because msMsgSetPtrShared takes the message's atomic incref at pack and the generated _impl releases exactly once through a synthesized finally. send=2100000 (300000x7) proves the SEND payload survived the sender's scope exit; call=1500000 (300000x5) proves the CALL leg round-trips; flat RSS proves the boundary incref is released, not leaked, on both paths. Bound 40-to-20 + rounds 2000-to-300000 (2026-09-04 RSS audit): measured steady-state ~8.6MB (Linux drc); the old shape left 34.7MB slack over 2k rounds - blind under 18KB/round, unable to see its own guarded class (~65-130B/round of leaked Arc cell + payload). 20 keeps 2.3x headroom while a single-leg boundary leak (~20-39MB at 300k rounds) now trips.

struct Payload { buf: string; n: int32; }

actor Sink {
	total: int32 = 0;

	// SEND-class: void method, so the sender cannot park on a reply. Only an
	// Arc<T> may cross here — a plain ref is the UAF this pins (guard
	// paralockActorVerbs holds the compile-time half).
	absorb(p: Arc<Payload>): void { this.total = this.total + p.n; }

	// CALL: reply-bearing and awaited, so the same handle is a BORROW.
	weigh(p: Arc<Payload>): int32 { return p.n; }

	report(): int32 { return this.total; }
}

function main(): void {
	const sink = new Sink();
	let call = 0;
	for (let round = 0; round < 300000; round = round + 1) {
		const shared: Arc<Payload> = new Arc({ buf: "arc-actor-payload", n: 7 });
		sink.absorb(shared);
		const borrowed: Arc<Payload> = new Arc({ buf: "arc-actor-borrow", n: 5 });
		call = call + await sink.weigh(borrowed);
	}
	const send = await sink.report();
	console.log(`arc-actor-boundary send=${send} call=${call}`);
}

main();
