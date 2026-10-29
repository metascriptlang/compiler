// @stdout: spawn caught 3 x
// @stdout: then caught 3 y
// note: a task that fails hands its error to its future and keeps no count of its own, so a spawned task and a .then callback that throw, each three times, leave no Error behind once the failures are read.

function fail(why: string): int32 { throw new Error(why); }

async function one(): Promise<int32> { return 1; }

async function main(): Promise<void> {
	let spawned = 0;
	let last = "";
	for (let i = 0; i < 3; i += 1) {
		try {
			await spawn((): int32 => fail("x"));
		} catch (e) { spawned += 1; last = e.message; }
	}
	console.log(`spawn caught ${spawned} ${last}`);
	let thens = 0;
	for (let i = 0; i < 3; i += 1) {
		try {
			await one().then((v: int32): int32 => fail("y"));
		} catch (e) { thens += 1; last = e.message; }
	}
	console.log(`then caught ${thens} ${last}`);
}

await main();
