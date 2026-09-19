import { lockedUpdate, lockedRead } from "std/core/promise";

actor Tally {
	static readonly hits: Locked<int32> = new Locked<int32>(0);
	bump(): int32 {
		lockedUpdate(Tally.hits, (v: int32): int32 => v + 1);
		return 1;
	}
}

async function main(): Promise<int32> {
	const a = new Tally();
	const b = new Tally();
	for (let i = 0; i < 500; i = i + 1) {
		const x = await a.bump();
		const y = await b.bump();
	}
	const total = lockedRead(Tally.hits, (v: int32): int32 => v);
	if (total != 1000) {
		console.log(`GUARD-FAIL lockedStaticSharedAcrossInstances: got ${total}, want 1000`);
		return 1;
	}
	console.log("GUARD-OK actorStaticLocked");
	return 0;
}

const rc = await main();
if (rc != 0) { process.exit(rc); }
