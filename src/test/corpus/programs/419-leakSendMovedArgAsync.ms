// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native sync-context await
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @maxrss: 60
// @stdout: leak-send-moved-arg-async done
// @serial
// @ledger-slack(Sink) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: Sibling of 418 (sync void, FIXED). This pins the async half. History of
//   what this program caught, in order:
//   (1) the moved-ref leak — FIXED; the ledger on this shape at 2k sends reports
//   Box 2000/2000 (pre-release-fix compiler: 2000/0).
//   (2) the spawn-inside-actor HANG — FIXED 2026-09-05, two independent runtime
//   defects, both Windows-frequent (POSIX timing mostly dodged them): (a)
//   msFutureAddCallback vs msFutureFireCallbacks were unsynchronized, so a
//   callback appended by a stolen-visit worker while another thread completed
//   and fired the future stranded on a finished future and never ran; (b)
//   msAsyncStart on Windows created a thread-local dispatcher on pool workers
//   (POSIX had the msIsPoolWorker guard, Windows did not), and a worker with
//   its own IOCP routed every later completion to a port no thread drains —
//   steppers never fired, the actor suspended forever (repro: 30k sends, ~50%
//   of runs hung at 0.05s-per-clean-run; post-fix 25/25 and 6/6 at 1.2M on
//   both hosts).
//   (3) the per-dispatch `implFut` leak — FIXED 2026-10-20 (PARALOCK-runtime
//   Amendment S). The @maxrss bound sits between a resume that releases the
//   dispatch's future (10 MB, macOS) and one that never does (120 MB: 96 B ×
//   1.2M). The ledger cannot see that leak (Box balances; `Sink 1/0` and
//   `msFuture N/0` are the known blind patterns: runtime-freed actor shell,
//   NULL destroyFn).
//   RSS is the only assertion: the running total is NOT checked anywhere. The
//   periodic `await s.get()` bounds the message backlog.
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
		if ((i % 10000) == 9999) { await s.get(); }
	}
	console.log("leak-send-moved-arg-async done");
}
main();
