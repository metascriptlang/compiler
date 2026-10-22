// @stdout: skipped some=true
// @stdout: entered after exit=0
// @stdout: pending=0
// @stdout: async skipped some=true
// @stdout: async entered after exit=0
// @stdout: async pending=0
// @stdout: churn ok
// @serial
// @skip-raiser: msPoolPendingPeek reads the C runtime worker pool
// @skip-js: spawn on JS is a microtask that starts after the routine has left, and the JS backend has no exit join for held handles yet: lowerHeldSpawns runs for C only
// note: a routine that leaves while the handles of tasks borrowing from it (they read its `Pace`) still wait for a worker in an array cancels those tasks before it joins, so a task no worker admitted before the exit never runs. Each routine queues far more 100 ms tasks than there are workers and throws once one has started; the caller reads the entered count right after the routine has left and again 400 ms later, so `entered after exit=0` means no task body started after the exit, `pending=0` (the C pool's queued-task count, read once the cancelled tasks have drained) means each cancelled task left the count exactly once, and `skipped some=true` means the exit did not run every queued task (old compiler: bodies keep starting after the exit; a join without the cancel runs all of them).

import { lockedUpdate, lockedRead } from "std/core/promise";

extern function msPoolPendingPeek(): int32;

struct Count { entered: int32; }

class Pace { ms: number = 100; }

const queued: int32 = 256;

function busy(s: Locked<Count>, p: Readonly<Pace>): int32 {
	lockedUpdate(s, (c: Count): Count => { return { entered: c.entered + 1 }; });
	const until = Date.now() + p.ms;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + 1) % 1000;
	return n;
}

function entered(s: Locked<Count>): int32 {
	return lockedRead(s, (c: Count): int32 => { return c.entered; });
}

function pause(ms: number): void {
	const until = Date.now() + ms;
	while (Date.now() < until) {}
}

function leaveSaturated(s: Locked<Count>, p: Pace): int32 {
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < queued; k += 1) hs.push(spawn(() => busy(s, p)));
	while (entered(s) < 1) {}
	if (hs.length > 0) { throw "saturated"; }
	let t: int32 = 0;
	for (const h of hs) { t = t + await h; }
	return t;
}

async function leaveSaturatedAsync(s: Locked<Count>, p: Pace): Promise<int32> {
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < queued; k += 1) hs.push(spawn(() => busy(s, p)));
	while (entered(s) < 1) {}
	if (hs.length > 0) { throw "saturated"; }
	const rs = await Promise.all(hs);
	return rs.length;
}

function report(label: string, s: Locked<Count>): void {
	const atExit = entered(s);
	pause(400);
	console.log(`${label}skipped some=${atExit < queued}`);
	console.log(`${label}entered after exit=${entered(s) - atExit}`);
	console.log(`${label}pending=${msPoolPendingPeek()}`);
}

function fresh(): Locked<Count> {
	return new Locked({ entered: 0 });
}

function churn(): int32 {
	let t: int32 = 0;
	for (let i = 0; i < 200000; i += 1) {
		const xs: int32[] = [i % 7, i % 5];
		t = (t + xs[0] + xs[1]) % 1000003;
	}
	return t;
}

let total: int32 = 0;
const s1 = fresh();
const pace = new Pace();
try { total = leaveSaturated(s1, pace); } catch (e) { report("", s1); }
total = total + churn();
const s2 = fresh();
try { total = total + await leaveSaturatedAsync(s2, pace); } catch (e) { report("async ", s2); }
total = total + churn();
console.log(total > 0 ? "churn ok" : "churn lost");
