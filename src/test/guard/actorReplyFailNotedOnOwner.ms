// nim-guard: a CALL reply failed by the thread that reaps the actor is noted for the exit report on the owner of its count
//
// INVARIANT (ULTRALOCK M3): a rc op on a plain-rc cell runs on the thread that owns it. The reply future
//   of a CALL a spawned task sent is counted by that task's thread; main reaps the stopped actor and fails
//   the replies still queued, so the unhandled-rejection note must reach the owner as a queued message.
//
// WHAT IT CATCHES: the note taking its count on the reaping thread; TSan reports the race on the future's rc.
//
// RED MEANS: msNoteOrphanFailure touched the count of a future published to another thread.
//
// GUARD-TSAN
import { stop, ExitReason } from "std/actor";
import { exit } from "std/process";

actor Slow {
	work(this: Readonly<Slow>, x: int32): int32 {
		let s: int32 = 0;
		for (let i: int32 = 0; i < 200000; i += 1) s += i & x;
		return s;
	}
}

async function oneSender(): Promise<void> {
	const a = new Slow();
	const f = spawn(() => {
		for (let i: int32 = 0; i < 40; i += 1) { const p = a.work(i); }
		return 1;
	});
	await f;
	stop(a.pid, ExitReason.Normal);
}

async function twoSenders(): Promise<void> {
	const a = new Slow();
	const b = new Slow();
	const fa = spawn(() => {
		for (let i: int32 = 0; i < 40; i += 1) { const p = a.work(i); }
		return 1;
	});
	const fb = spawn(() => {
		for (let i: int32 = 0; i < 40; i += 1) { const p = b.work(i); }
		return 1;
	});
	await fa;
	await fb;
	stop(a.pid, ExitReason.Normal);
	stop(b.pid, ExitReason.Normal);
}

async function main(): Promise<void> {
	for (let k: int32 = 0; k < 10; k += 1) await oneSender();
	for (let k: int32 = 0; k < 10; k += 1) await twoSenders();
	console.log("GUARD-OK");
	exit(0);
}
await main();
