// @maxrss: 40
// @stdout: leak-send-moved-arg done
// @serial
// @xfail(drc): OPEN BUG (Part 2, PARALOCK amendment pending) — a fire-and-forget
//   SEND of a moved plain ref transfers ownership into the message, but the actor
//   side never releases it: the dispatch passes msMsgGetPtr to the _impl, and
//   wrapImplBodyWithShareRelease only releases Arc/SHARE args. 1 leak per send
//   (ledger: alloc=N destroy=0). Fix needs a message-carried owned bit + release
//   at dispatch (Nim channel send/recv semantics) — PARALOCK.md owner's call.
// @xfail(orc): same as drc
// @xfail(danger): same as drc
// note: The sibling 417 pins the FIXED borrow-position shapes (fn move, awaited
// CALL move). This program pins the still-open SEND-class handoff: s.take(move b)
// with take void — the caller correctly drops its destroy (ownership crosses into
// the mailbox) and nobody on the actor side destroys the Box. XPASS on any native
// lane announces the Part 2 fix landed — then drop the xfails.
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
	}
	const t = await s.get();
	if (t !== 1200000) { console.log("FAIL actor sum"); process.exit(1); }
	console.log("leak-send-moved-arg done");
}
main();
