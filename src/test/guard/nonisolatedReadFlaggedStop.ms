// Each round stops the actor while four readers are inside a nonisolated read of a large string: the
// read is the pinned window, and a reader never begins a read after it reported entering its only one,
// because a read that begins after teardown is the runtime's fatal "has stopped" exit, not a catchable error.
// RED MEANS: teardown destroyed the state under a pinned read. On the base compiler this is red
// under ASan and TSan by count (use-after-free in some runs), not deterministically.
//
// GUARD-TSAN

import { nonisolated, stop, ExitReason } from "std/actor";
import { sleepAsync, lockedUpdate, lockedRead } from "std/core/promise";

const SIZE = 4194304;
const READERS = 4;
const ROUNDS = 40;

actor Srv {
	@nonisolated
	readonly name: string = "s".repeat(4194304);
	ping(): int32 { return 1; }
}

const entered = new Locked<int32>(0);

async function round(): Promise<int64> {
	const s = new Srv();
	await s.ping();
	lockedUpdate(entered, (v: int32): int32 => 0);
	const readers: Promise<int64>[] = [];
	for (let k = 0; k < READERS; k = k + 1) {
		readers.push(spawn((): int64 => {
			lockedUpdate(entered, (v: int32): int32 => v + 1);
			const v = s.name;
			return v.length;
		}));
	}
	while (lockedRead(entered, (v: int32): int32 => v) < READERS) await sleepAsync(1);
	await sleepAsync(1);
	stop(s.pid, ExitReason.Normal);
	let sum: int64 = 0;
	for (const r of readers) sum = sum + await r;
	return sum;
}

async function main(): Promise<int32> {
	for (let i = 0; i < ROUNDS; i = i + 1) {
		const sum = await round();
		if (sum != SIZE * READERS) {
			console.log(`GUARD-FAIL round ${i} read ${sum}`);
			return 1;
		}
	}
	console.log("GUARD-OK");
	return 0;
}

const rc = await main();
if (rc != 0) process.exit(rc);
