// Reads, stop and restart in a loop leave the DRC ledger balanced: teardown defers the state's
// destruction only while a read pins it, and then destroys it exactly once.
// RED MEANS: a stopped actor's state is destroyed twice or never (ledger abort or imbalance).
// GUARD-BALANCE Srv

import { nonisolated, stop, ExitReason } from "std/actor";
import { sleepAsync } from "std/core/promise";

actor Srv {
	@nonisolated
	readonly name: string = "s".repeat(64);
	@nonisolated
	readonly count: int32 = 3;
	ping(): int32 { return 1; }
}

async function main(): Promise<int32> {
	let total: int64 = 0;
	for (let k = 0; k < 100; k = k + 1) {
		const s = new Srv();
		await s.ping();
		total = total + s.name.length + s.count;
		stop(s.pid, ExitReason.Normal);
	}
	await sleepAsync(50);
	if (total != 6700) {
		console.log("GUARD-FAIL total=" + total.toString());
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const rc = await main();
if (rc != 0) process.exit(rc);
