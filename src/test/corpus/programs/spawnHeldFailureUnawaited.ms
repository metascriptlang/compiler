// @xfail(raiser): the Raiser VM has no spawn pool threads, Locked cell or exit join, which this program pins (no host bridge for msLockedHeldHere/msLockedAcquire, and Locked has no constructor)
// @stdout: returned 3
// @stdout: Error: unhandled rejection: held task failed in a return
// @exit: 1
// @serial
// @skip-js: spawn on JS is a microtask that starts after the routine has left, and the JS backend has no exit join for held handles yet: lowerHeldSpawns runs for C only
// note: a task kept in an array that fails while its routine returns normally, with nobody awaiting it, is an unhandled rejection: the exit join waits for it, the program reports it when it ends and exits 1, as node does for a rejected promise nobody awaited (SAN ledger: Error alloc == destroy). Each routine returns only after all three tasks have started, so the exit's cancel (T5) cannot skip the failing one. Sync routine; the async routine is spawnHeldFailureUnawaitedAsync, a separate program so that each reports exactly one rejection and the parity compare has a single order. The program never turns the event loop, so the exit itself must take the completion the finished task posted: without it the program exits 0 with no report and msFuture alloc != destroy.

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Count { started: int32; }

function work(n: int32, why: string, s: Locked<Count>): int32 {
	lockedUpdate(s, (c: Count): Count => { return { started: c.started + 1 }; });
	if (n == 1) { throw new Error(why); }
	return n;
}

function started(s: Locked<Count>): int32 {
	return lockedRead(s, (c: Count): int32 => { return c.started; });
}

function leave(): int32 {
	const s: Locked<Count> = new Locked({ started: 0 });
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < 3; k += 1) {
		const n = k;
		hs.push(spawn(() => work(n, "held task failed in a return", s)));
	}
	while (started(s) < 3) {}
	return hs.length;
}

console.log(`returned ${leave()}`);
