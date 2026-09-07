// @stdout: spawn-only done
// @maxrss: 16
// @serial

// note: Regression guard for spawn futures that are STORED and then DROPPED
// without ever being awaited. The historic Windows hole (surfaced by the
// process-global IOCP): the worker's completion post incref'd the future's
// non-atomic rc on the worker thread, racing the owning thread's array-drop
// decref on the same field — heap corruption after a few thousand spawns even
// with int payloads (no boxing involved). Fix is Amendment G/H reaching
// Windows: MS_FUTURE_SUBMIT_REF=1 takes the in-flight ref on the OWNER thread
// at submit, the Owned post takes no ref, and the drain (plus the
// crossThreadPublished deferred release at array drop) is the only thread
// that decrefs — identical to the POSIX flow this design always specified.
// This cell drops every future unread: an rc imbalance crashes here (exit≠0),
// a leak doubles RSS. Kept int-typed to pin the pure rc path, independent of
// string/struct boxing. NOTE on the RSS gate: futures dropped unawaited stay
// alive until the EXIT drain by design (the submit ref is only released when
// the completion message is processed, and a no-await program never runs the
// loop mid-flight) — POSIX behaves identically. The budget therefore covers
// the deferred population, 16k spawns ≈ 9MB observed, and still catches a
// real rc leak (which grows without bound past it).
function run(): void {
	let batch = 0;
	while (batch < 4000) {
		const futs: Promise<number>[] = [];
		let k = 0;
		while (k < 4) {
			const kk = k;
			futs.push(spawn(() => { return kk; }));
			k = k + 1;
		}
		batch = batch + 1;
	}
	console.log("spawn-only done");
}

run();
