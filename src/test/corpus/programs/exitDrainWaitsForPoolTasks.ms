// @skip-js: a spawn thunk awaits here, a blocking wait the JS backend refuses (checker/syncAwait.ms); the program pins the native exit drain
// @stdout: helped int 0
// @stdout: helped string 0-done
// @stdout: helped twice 0
// @stdout: timer-bound 21
// @serial

// note: The exit drain must not return while a pool task is still in flight. Each
//   shape below is awaited by an async function after the entry module returned, so
//   only the drain keeps the program alive. A worker that awaits a child helps and
//   runs it inline, and a worker parked on a loop-completed future has stepped out
//   of the busy count; both used to leave the drain reading an idle pool and exiting
//   0 with no output (helped shapes ~9/10 runs, timer-bound ~1/40).
function spin(n: int32): int32 {
	let acc = 0;
	for (let i = 0; i < n; i++) acc = (acc + i) % 1000;
	return acc;
}

async function run(): Promise<void> {
	const ints = [spawn(() => {
		const inner = spawn(() => spin(30000000));
		return await inner;
	})];
	for (const h of ints) console.log(`helped int ${await h}`);

	const strings = [spawn(() => {
		const inner = spawn(() => `${spin(30000000)}-done`);
		return await inner;
	})];
	for (const h of strings) console.log(`helped string ${await h}`);

	const twice = [spawn(() => {
		const mid = spawn(() => {
			const inner = spawn(() => spin(30000000));
			return await inner;
		});
		return await mid;
	})];
	for (const h of twice) console.log(`helped twice ${await h}`);

	const timed = [spawn(() => { await sleepAsync(1); return 21; })];
	for (const h of timed) console.log(`timer-bound ${await h}`);
}

run();
