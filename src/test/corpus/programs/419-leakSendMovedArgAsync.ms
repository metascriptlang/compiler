// @maxrss: 30
// @stdout: leak-send-moved-arg-async done
// @serial
// @xfail(drc): OPEN BUG (actor spawn suspension) — NOT the leak any more. The
//   moved-ref leak this program was written for is FIXED: the impl-side release
//   (actorLower wrapImplBodyWithShareRelease) is no longer gated off for
//   await-containing bodies now that try×await splits (corpus 420), and the DRC
//   ledger on this exact shape at 2k sends reports Box 2000/2000 where the
//   pre-fix compiler reported 2000/0. What is still red is a DIFFERENT,
//   PRE-EXISTING defect this xfail was masking all along: an actor method that
//   spawns and awaits the handle HANGS probabilistically under a message backlog
//   — 3 to 5 runs in 6 at 30k sends, while a completing run takes 0.05s, so it is
//   a lost wakeup, not slowness. Reproduced identically on the baseline compiler
//   that predates every fix in this family (4/6), and isolated by two controls
//   that drain 6/6 clean: a sync actor method, and an async actor method awaiting
//   a plain async function (no spawn). The trigger is spawn-inside-actor
//   (PARALOCK §7.2 suspension ↔ worker pool), not the release and not the leak.
//   Whoever fixes the hang must re-measure the bound before flipping this green:
//   with the release restored the in-flight suspended-take envs, not the
//   messages, set the new floor.
// @xfail(orc): same as drc
// @xfail(danger): same as drc
// @xfail(san): same as drc — the hang trips the lane's timeout before the ledger
//   can be read (the ledger balance itself was verified separately at 2k sends)
// @xfail(esm): tree emit: native Promise.resolve shadowed by the emitted class Promise in _std/core/promise
// note: Sibling of 418 (sync void, FIXED). This pins the async half. RSS is the
//   only assertion: the running total is NOT checked anywhere, because a
//   suspending `take` does not hold up the mailbox — `get()` is answered while
//   earlier takes are still parked on their spawn, so any total read mid-loop or
//   right after it is a scheduling sample, not an invariant (a bounded settle
//   loop was tried and flaked under ASan). The periodic `await s.get()` only
//   bounds the message backlog so peak RSS measures the leak rather than queue
//   depth — the mistake the original 418 made.
//   The ledger, not RSS, is what proved the release: this shape at 2k sends
//   (barrier every 500, small enough to clear the hang) reports Box 2000/2000
//   on the fixed compiler and Box 2000/0 on the pre-fix one. `Sink 1/0` and
//   `msFuture N/0` there are the two known ledger blind patterns (runtime-freed
//   actor shell, NULL destroyFn), not leaks.
//   RELATED: an `Arc<T>` param on an async actor method takes the SHARE release,
//   which was never gated, so that shape also wrapped an await in try/finally —
//   it failed to BUILD on every native lane until the try×await split landed
//   (420). It builds now; no program pins it yet.
interface Box { v: int32; }
actor Sink {
	seen: int32 = 0;
	take(b: Box): void {
		const w = spawn(() => 1);
		const n = await w;
		this.seen = this.seen + b.v + (n - 1);
	}
	get(): int32 { return this.seen; }
}
function main(): void {
	const s = new Sink();
	for (let i = 0; i < 1200000; i = i + 1) {
		const b: Box = { v: 1 };
		s.take(move b);
		if ((i % 10000) === 9999) { await s.get(); }
	}
	console.log("leak-send-moved-arg-async done");
}
main();
