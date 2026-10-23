// A nonisolated read sits where its operand order puts it: the right side of a short-circuit
// and the untaken arm of a ternary do not pin, so a stopped actor is never read there.
// RED MEANS: the read is hoisted out of its guarded position and meets the stopped actor.

import { nonisolated, stop, ExitReason } from "std/actor";
import { sleepAsync } from "std/core/promise";

actor Srv {
	@nonisolated
	readonly name: string = "srv";
	ping(): int32 { return 1; }
}

async function main(): Promise<int32> {
	const s = new Srv();
	await s.ping();
	stop(s.pid, ExitReason.Normal);
	await sleepAsync(100);
	const never = s.pid < 0;
	let rc: int32 = 0;
	if (never && s.name.length > 0) rc = 1;
	if ((never ? s.name : "alt") != "alt") rc = 1;
	if (never || s.pid < 0) rc = 1;
	if (rc != 0) {
		console.log("GUARD-FAIL guarded read ran");
		return rc;
	}
	console.log("GUARD-OK");
	return 0;
}

const rc = await main();
if (rc != 0) process.exit(rc);
