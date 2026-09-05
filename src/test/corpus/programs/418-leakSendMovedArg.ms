// @maxrss: 30
// @stdout: leak-send-moved-arg done
// @serial
// note: FIXED (actorLower wrapImplBodyWithShareRelease): a fire-and-forget SEND of
//   a moved plain ref transfers ownership into the message; the void _impl now
//   releases it in its try/finally (msDecref, or msDecrefCyclic for cycle-capable
//   pointees) — sound because the checker confines plain refs at SEND-class calls
//   to `move` (I21), and a void method cannot be awaited, so no borrow shape ever
//   reaches a void _impl. Arrays ride the same path post-array-migration (the
//   param type is Ref<ArrayCell>). Proven: ledger Box alloc=destroy at 100 and
//   the array shape balances too; awaited CALL shapes (417) unchanged.
//   The periodic `await s.get()` every 10k sends is a drain sync point, not a
//   semantic check (though it self-checks the running total): msActorSend is
//   wait-free with no backpressure, so a tight 1.2M-send loop's PEAK RSS is the
//   mailbox backlog (~112 B/msg ≈ 98 MB on a fast sender) — the ORIGINAL form of
//   this program measured that backlog, not the leak, and was un-greenable even
//   with a perfect fix (98.1 MB before vs 97.6 MB after). With syncs the backlog
//   is bounded at 10k msgs (~1 MB); a regression of the leak re-adds ~38 MB, so
//   both margins around the 30 MB bound are wide (green ~5 MB, red ~43 MB) and a
//   PARTIAL regression (say refs released but arrays not) still goes red.
//   The sync is a hard barrier, not a timing guess: `take` never suspends and the
//   mailbox is FIFO, so the reply to `get()` cannot complete before every earlier
//   take has been dispatched — hence the running total is asserted, not sampled.
//   If dispatch ever becomes out-of-order, THAT is what turns this program red.
interface Box { v: int32; }
actor Sink {
	seen: int32 = 0;
	take(b: Box): void { this.seen = this.seen + b.v; }
	get(): int32 { return this.seen; }
}
function main(): void {
	const s = new Sink();
	for (let i = 0; i < 1200000; i = i + 1) {
		const b: Box = { v: 1 };
		s.take(move b);
		if ((i % 10000) === 9999) {
			const t = await s.get();
			if (t !== i + 1) { console.log("FAIL actor sum"); process.exit(1); }
		}
	}
	const t = await s.get();
	if (t !== 1200000) { console.log("FAIL actor sum"); process.exit(1); }
	console.log("leak-send-moved-arg done");
}
main();
