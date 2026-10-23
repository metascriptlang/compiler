// @stdout: Error: an await of a promise blocks while spawned tasks stay queued, and none of the 64 pool threads is free to run them (thread limit reached)
// @exit: 1
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait blocks a worker
// @xfail(san): the error stops the program with _exit, which skips the exit-time ledger dump, and the tasks it stops are never destroyed
// note: a thousand tasks each await a promise that the main thread resolves only after a later-queued child has run. Each such wait starts a spare thread for the queue, and past the 64-thread limit the runtime stops with an error naming the wait instead of running unrelated queued work inside it (which can deadlock the waiter on its own stack) or hanging. The stop is `_exit(1)`, because `exit()` would join the starved threads and hang; `_exit` also skips the exit-time DRC ledger dump, so the SAN lane reads no ledger here and the tasks still in flight are never destroyed, which is the stop and not a leak (`@xfail(san)`). The tasks borrow their promise, so each level spawns, recurses, then awaits its own task in its own scope.
let resolvers: ((v: int32) => void)[] = [];

function fan(i: int32, n: int32): int32 {
	if (i == n) {
		for (const res of resolvers) spawn(() => 5 as int32).then((v: int32): void => res(v));
		return 0;
	}
	const gate = new Promise<int32>((res) => { resolvers.push(res); });
	const h = spawn(() => await gate);
	const rest = fan(i + 1, n);
	return rest + await h;
}

console.log(`sum=${fan(0, 1000)}`);
