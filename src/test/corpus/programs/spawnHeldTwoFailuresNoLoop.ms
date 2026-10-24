// @xfail(raiser): the Raiser VM has no spawn pool threads, Locked cell or exit join, which this program pins (no host bridge for msLockedHeldHere/msLockedAcquire, and Locked has no constructor)
// @stdout: returned 3
// @stdout: Error: unhandled rejection: two held tasks failed
// @exit: 1
// @serial
// @skip-js: spawn on JS is a microtask that starts after the routine has left, and the JS backend has no exit join for held handles yet: lowerHeldSpawns runs for C only
// note: two tasks kept in an array both fail while their routine returns normally, and the program never turns the event loop: the exit takes both posted completions and reports both, exit 1. Both throw the same message so either order prints the same output and the c-vs-danger compare has one order; the runner matches a line by `contains` and cannot count two, so a lost second report shows as a SAN ledger imbalance (msFuture alloc != destroy).

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Count { started: int32; }

function work(n: int32, why: string, s: Locked<Count>): int32 {
	lockedUpdate(s, (c: Count): Count => { return { started: c.started + 1 }; });
	if (n < 2) { throw new Error(why); }
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
		hs.push(spawn(() => work(n, "two held tasks failed", s)));
	}
	while (started(s) < 3) {}
	return hs.length;
}

console.log(`returned ${leave()}`);
