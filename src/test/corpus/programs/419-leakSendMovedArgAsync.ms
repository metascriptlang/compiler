// @maxrss: 30
// @stdout: leak-send-moved-arg-async done
// @serial
// @xfail(drc): OPEN BUG (Part 3) — an ASYNC void SEND of a moved plain ref still
//   leaks: the impl-side release (landed for sync voids in 418's fix,
//   actorLower wrapImplBodyWithShareRelease) is gated OFF for await-containing
//   bodies, because wrapping an await body in try/finally trips the PRE-EXISTING
//   async-lowering gap pinned by 420 — a YieldExpr inside a try body survives to
//   C codegen. Until 420 goes XPASS, async void methods keep the old behavior
//   (they compile, and leak 1 ref per send).
// @xfail(orc): same as drc
// @xfail(danger): same as drc
// @xfail(san): same leak, seen by the ledger as an unbalanced moved Box
// @xfail(esm): tree emit: native Promise.resolve shadowed by the emitted class Promise in _std/core/promise
// note: Sibling of 418 (sync void, FIXED). This pins the async half. RSS is the
//   only assertion: the running total is NOT checked anywhere, because a
//   suspending `take` does not hold up the mailbox — `get()` is answered while
//   earlier takes are still parked on their spawn, so any total read mid-loop or
//   right after it is a scheduling sample, not an invariant (a bounded settle
//   loop was tried and flaked under ASan). The periodic `await s.get()` only
//   bounds the message backlog so peak RSS measures the leak (~38 MB at 1.2M)
//   rather than queue depth — the mistake the original 418 made.
//   Whoever lands Part 3 must re-measure the bound: with the release restored,
//   the in-flight suspended-take envs, not the messages, set the new floor.
//   RELATED, NOT PINNED HERE: an `Arc<T>` param on an async actor method takes
//   the SHARE release, which is deliberately NOT gated, so that shape wraps an
//   await in try/finally too and fails to BUILD on the native lanes today (it
//   was already broken before the 418 fix, with a transform-level error instead
//   of a codegen one). 420 is the pin for the underlying gap.
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
