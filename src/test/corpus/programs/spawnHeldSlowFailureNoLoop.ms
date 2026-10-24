// @xfail(raiser): the Raiser VM has no spawn pool threads, Locked cell or exit join, which this program pins (no host bridge for msLockedHeldHere/msLockedAcquire, and Locked has no constructor)
// @stdout: returned 3
// @stdout: Error: unhandled rejection: slow task failed
// @exit: 1
// @serial
// @skip-js: spawn on JS is a microtask that starts after the routine has left, and the JS backend has no exit join for held handles yet: lowerHeldSpawns runs for C only
// note: a held task that is still running when its routine returns and then fails, in a program that never turns the event loop, is joined by the routine exit and reported when the program ends with exit 1 (SAN ledger: msFuture alloc == destroy). The sibling of spawnHeldFailureUnawaited, whose task fails at once. Red on the build before the held-spawn join, where the program ends first and exits 0.

import { lockedUpdate, lockedRead } from "std/core/promise";
struct Count { started: int32; done: int32; }
function bump(s: Locked<Count>, d: int32): void { lockedUpdate(s, (c: Count): Count => { return { started: c.started + 1 - d, done: c.done + d }; }); }
function startedOf(s: Locked<Count>): int32 { return lockedRead(s, (c: Count): int32 => { return c.started; }); }
function slow(n: int32, fail: boolean, s: Locked<Count>): int32 {
	bump(s, 0);
	let sum: int32 = 0;
	if (n == 1) { for (let r = 0; r < 20000000; r += 1) sum = (sum + r) % 1000003; }
	if (n == 1 && fail) { throw new Error("slow task failed"); }
	if (n == 1) { console.log("slow done " + sum.toString()); }
	return n;
}
function leave(fail: boolean): int32 {
	const s: Locked<Count> = new Locked({ started: 0, done: 0 });
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < 3; k += 1) { const n = k; hs.push(spawn(() => slow(n, fail, s))); }
	while (startedOf(s) < 3) {}
	return hs.length;
}
console.log("returned " + leave(true).toString());
