// Readers loop on a nonisolated string field and quit on a flag the parent sets before stop, so a read
// can still be in flight while the actor tears down, and the program exits 0 on either interleaving.
// RED MEANS: teardown destroyed the state under a pinned read. On the base compiler this is red
// under ASan by count (use-after-free in some runs), not deterministically.
//
// GUARD-TSAN

import { nonisolated, stop, ExitReason } from "std/actor";
import { sleepAsync, lockedUpdate, lockedRead } from "std/core/promise";

actor Srv {
	@nonisolated
	readonly name: string = "s".repeat(4096);
	ping(): int32 { return 1; }
}

const quit = new Locked<boolean>(false);

async function main(): Promise<int32> {
	const s = new Srv();
	await s.ping();
	const readers: Promise<int64>[] = [];
	for (let k = 0; k < 4; k = k + 1) {
		readers.push(spawn((): int64 => {
			let total: int64 = 0;
			while (!lockedRead(quit, (v: boolean): boolean => v)) {
				const v = s.name;
				total = total + v.length;
			}
			return total;
		}));
	}
	await sleepAsync(20);
	lockedUpdate(quit, (v: boolean): boolean => true);
	stop(s.pid, ExitReason.Normal);
	let sum: int64 = 0;
	for (const r of readers) sum = sum + await r;
	if (sum <= 0) return 1;
	console.log("GUARD-OK");
	return 0;
}

const rc = await main();
if (rc != 0) process.exit(rc);
