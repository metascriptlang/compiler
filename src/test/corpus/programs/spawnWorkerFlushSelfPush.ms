// @stdout: tasks=3200
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS has no pool worker, so no worker parks
// note: each pool task calls an async function and returns without awaiting it; the function awaits two spawns, so the worker that runs the task owns both futures' callbacks and their deferred releases, while the spawns complete from other workers into its loop channel. Flushing those releases pushes into the worker's own channel, a push that sends no wake, and the worker used to park right after with the message unread: the program never ended (old runtime: hang in 8 of 10 runs, killed by the timeout; actor neighbours 1114-actorSuspendStop and actorSuspendedDispatchReleasesItsFuture).
async function child(): Promise<int32> {
	const a = spawn(() => 1 as int32);
	const b = spawn(() => 2 as int32);
	return await a + await b;
}

function task(): int32 {
	child();
	return 1;
}

let n: int32 = 0;
for (let round = 0; round < 50; round++) {
	const hs: Promise<int32>[] = [];
	for (let i = 0; i < 64; i++) hs.push(spawn(() => task()));
	for (const h of hs) n += await h;
}
console.log(`tasks=${n}`);
