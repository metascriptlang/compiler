// @maxrss: 200
// @stdout: leak-send-moved-arg-async done
// @serial
// @xfail(esm): tree emit: native Promise.resolve shadowed by the emitted class Promise in _std/core/promise
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
//   The @maxrss bound is the completing program's real floor, measured after
//   the hang fix made completion reachable at all: peak ≈ 133 MB (Windows) /
//   172 MB (Linux) — the in-flight parked-take set (envs + futures + spawn
//   tasks the event loop has not drained yet), NOT a per-send leak; the ledger
//   stays the leak signal (Box balances; `Sink 1/0` and `msFuture N/0` are the
//   known blind patterns: runtime-freed actor shell, NULL destroyFn).
//   RSS is the only assertion: the running total is NOT checked anywhere,
//   because a suspending `take` does not hold up the mailbox — `get()` is
//   answered while earlier takes are still parked on their spawn, so any total
//   read mid-loop is a scheduling sample, not an invariant. The periodic
//   `await s.get()` bounds the message backlog so peak RSS measures in-flight
//   state rather than queue depth.
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
