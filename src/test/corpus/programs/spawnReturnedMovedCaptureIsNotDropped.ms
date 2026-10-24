// @stdout: returned alive ok
// @stdout: dropped once ok
// @stdout: cancelled exact ok
// @serial
// @skip-js: JS has no spawn threads, so a moved capture is never dropped by a task there
// note: a moved capture the task returns is moved into the result, not dropped: it arrives alive at the await and its `onDestroy` runs once, when the parent lets go of it. The last block queues far more tasks than there are workers, each moving its own box and borrowing a `Pace`, and leaves the routine once a body has started: tasks no worker admitted never run their thunk, so the owner's env release still drops their boxes, and every box is dropped exactly once.

import { lockedUpdate, lockedRead } from "std/core/promise";

const dropped: Locked<int32> = new Locked(0);

class Box { v: int32; constructor(v: int32) { this.v = v; } }

function onDestroy(this x: Box): void {
	lockedUpdate(dropped, (c: int32): int32 => { return c + 1; });
}

function droppedNow(): int32 { return lockedRead(dropped, (c: int32): int32 => { return c; }); }

function ownerBusy(ms: number): void {
	const t1 = Date.now();
	while (Date.now() - t1 < ms) {}
}

async function returned(): Promise<Box> {
	const m = new Box(7);
	const f = spawn(() => m, { move: [m] });
	ownerBusy(100);
	return await f;
}

const before = droppedNow();
{
	const got = await returned();
	console.log(droppedNow() == before && got.v == 7 ? "returned alive ok" : `returned alive RED dropped=${droppedNow() - before}`);
}
console.log(droppedNow() - before == 1 ? "dropped once ok" : `dropped once RED dropped=${droppedNow() - before}`);

struct Entered { n: int32; }

class Pace { ms: number = 100; }

const queued: int32 = 64;

function enteredNow(s: Locked<Entered>): int32 {
	return lockedRead(s, (c: Entered): int32 => { return c.n; });
}

function busy(s: Locked<Entered>, p: Readonly<Pace>, b: Box): int32 {
	lockedUpdate(s, (c: Entered): Entered => { return { n: c.n + 1 }; });
	const until = Date.now() + p.ms;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + b.v) % 1000;
	return n;
}

function leaveSaturated(s: Locked<Entered>, p: Pace): int32 {
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < queued; k += 1) {
		const b = new Box(k);
		hs.push(spawn(() => busy(s, p, b), { move: [b] }));
	}
	while (enteredNow(s) < 1) {}
	if (hs.length > 0) { throw "saturated"; }
	return 0;
}

const mark = droppedNow();
const s: Locked<Entered> = new Locked({ n: 0 });
try { leaveSaturated(s, new Pace()); } catch (e) {}
const giveUp = Date.now() + 10000;
while (droppedNow() - mark < queued && Date.now() < giveUp) ownerBusy(20);
ownerBusy(200);
const entered = enteredNow(s);
console.log(droppedNow() - mark == queued && entered < queued ? "cancelled exact ok" : `cancelled exact RED dropped=${droppedNow() - mark} entered=${entered}`);
