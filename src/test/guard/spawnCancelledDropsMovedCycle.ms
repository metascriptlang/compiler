// guard: a cancelled task drops its moved cyclic capture exactly once
//
// INVARIANT (ULTRALOCK T5, T4, V3): a routine that throws while the borrowing tasks it holds in an
//   array still wait for a worker cancels them; a task no worker admitted completes its slot and
//   settles its captures under their custody, so each node of the cyclic ring moved into each
//   task, admitted or not, is destroyed exactly once (the Ring balance at exit; a ring left
//   behind is cyclic garbage the collector frees later, so the count is read at exit), and no
//   body starts after the exit. Axes: a held array in a sync routine and in an async function.
//
// RED MEANS: a skipped child left its captures in place (a ring is never destroyed, or is
//   destroyed twice), or a cancelled child still ran its body.
//
// GUARD-BALANCE Ring

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Count { entered: int32; }

const counts: Locked<Count> = new Locked({ entered: 0 });

class Ring {
	next: Ring | null = null;
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
}

class Pace { ms: number = 20; }

const QUEUED: int32 = 64;

function ringOf(tag: int32): Ring {
	const a = new Ring(tag);
	const b = new Ring(tag);
	a.next = b;
	b.next = a;
	return a;
}

function entered(): int32 { return lockedRead(counts, (c: Count): int32 => { return c.entered; }); }

function busy(r: Ring, p: Readonly<Pace>): int32 {
	lockedUpdate(counts, (c: Count): Count => { return { entered: c.entered + 1 }; });
	const until = Date.now() + p.ms;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + 1) % 1000;
	return n + r.tag * 0;
}

function pause(ms: number): void {
	const until = Date.now() + ms;
	while (Date.now() < until) {}
}

function leave(p: Pace): int32 {
	const hs: Promise<int32>[] = [];
	for (let k: int32 = 0; k < QUEUED; k += 1) {
		const r = ringOf(k);
		hs.push(spawn(() => busy(r, p), { move: [r] }));
	}
	while (entered() < 1) {}
	if (hs.length > 0) { throw "leave"; }
	let t: int32 = 0;
	for (const h of hs) { t = t + await h; }
	return t;
}

async function leaveAsync(p: Pace): Promise<int32> {
	const hs: Promise<int32>[] = [];
	for (let k: int32 = 0; k < QUEUED; k += 1) {
		const r = ringOf(k);
		hs.push(spawn(() => busy(r, p), { move: [r] }));
	}
	while (entered() < 1) {}
	if (hs.length > 0) { throw "leave"; }
	const rs = await Promise.all(hs);
	return rs.length;
}

let bad: int32 = 0;

function check(label: string): void {
	const atExit = entered();
	pause(200);
	const late = entered() - atExit;
	if (late != 0 || atExit >= QUEUED) {
		bad += 1;
		console.log(`${label}: entered after exit=${late} entered at exit=${atExit} of ${QUEUED}`);
	}
}

async function main(): Promise<void> {
	const p = new Pace();
	lockedUpdate(counts, (c: Count): Count => { return { entered: 0 }; });
	try { leave(p); } catch (e) { check("sync"); }
	lockedUpdate(counts, (c: Count): Count => { return { entered: 0 }; });
	try { await leaveAsync(p); } catch (e) { check("async"); }
	if (bad == 0) console.log("GUARD-OK");
	else process.exit(1);
}

main();
