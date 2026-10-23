// @stdout: Error: an await of a promise blocks while spawned tasks stay queued, and none of the 64 pool threads is free to run them (thread limit reached)
// @exit: 1
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait blocks a worker
// @xfail(san): the error stops the program with _exit, which skips the exit-time ledger dump, and the tasks it stops are never destroyed
// note: a thousand tasks each await a promise that only a later-queued child settles. Each such wait starts a spare thread for the queue, and past the 64-thread limit the runtime stops with an error naming the wait instead of running unrelated queued work inside it (which can deadlock the waiter on its own stack) or hanging.
function task(): int32 {
	const p = new Promise<int32>((res) => {
		spawn(() => 5 as int32).then((v: int32): void => res(v));
	});
	return await p;
}

const hs: Promise<int32>[] = [];
for (let i = 0; i < 1000; i++) hs.push(spawn(() => task()));
let s: int32 = 0;
for (const h of hs) s += await h;
console.log(`sum=${s}`);
