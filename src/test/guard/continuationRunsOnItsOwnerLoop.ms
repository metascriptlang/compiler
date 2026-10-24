// guard: a continuation runs on the thread that owns its future
//
// INVARIANT (ULTRALOCK A3): a future completed by a worker stores its result, and its callbacks
//   are drained on the future's owner. Two pool tasks pump their own event loops (as a
//   concurrent server does) while main starts async functions and `.then` callbacks on spawns,
//   then spins without pumping. Nothing main owns may resume while main spins: both counts stay
//   0 until main pumps its own loop, and then every continuation has run.
//
// RED MEANS: a continuation ran on a loop thread that is not its owner, concurrently with the
//   owner's code (msCompletionQueuePushOwned routed the completion to whichever loop drained).

import { msIoRunOnce } from "std/net";
import { sleepAsync, lockedUpdate, lockedRead } from "std/core/promise";

extern function msMonoTimeMs(): int64;

const LOOPS = 2;
const STARTED = 8;
let resumed = 0;
let thenRan = 0;
struct Stop { on: boolean; }

function pump(stop: Locked<Stop>): int32 {
	let n: int32 = 0;
	while (!lockedRead(stop, (s: Stop): boolean => { return s.on; })) {
		msIoRunOnce(1);
		n += 1;
	}
	return n;
}

async function work(): Promise<void> {
	await spawn(() => 7);
	resumed = resumed + 1;
}

function main(): void {
	const stop: Locked<Stop> = new Locked({ on: false });
	const loops: Promise<int32>[] = [];
	for (let i = 0; i < LOOPS; i += 1) loops.push(spawn(() => pump(stop)));
	for (let i = 0; i < STARTED; i += 1) {
		work();
		spawn(() => 3).then((v: int32): void => { thenRan = thenRan + v * 0 + 1; });
	}
	const until = msMonoTimeMs() + 500;
	while (msMonoTimeMs() < until) {}
	const resumedWhileMainSpun = resumed;
	const thenWhileMainSpun = thenRan;
	lockedUpdate(stop, (s: Stop): Stop => { return { on: true }; });
	for (const l of loops) await l;
	while (resumed < STARTED || thenRan < STARTED) await sleepAsync(1);
	if (resumedWhileMainSpun == 0 && thenWhileMainSpun == 0) console.log("GUARD-OK");
	else {
		console.log(`resumedWhileMainSpun=${resumedWhileMainSpun} thenWhileMainSpun=${thenWhileMainSpun}`);
		process.exit(1);
	}
}

main();
