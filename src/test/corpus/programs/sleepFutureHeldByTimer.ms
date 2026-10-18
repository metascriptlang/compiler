// @stdout: worker timers 10
// @stdout: loop race 1
// @serial
// @xfail(raiser): raiser runtime error: Unknown host function: msPromiseRace (no host bridge registers it in hostTable.ms)

// note: The timer heap keeps a sleep future alive until it has fired, and a worker's
//   sleep future is released on the loop thread that fires it. A dropped sleepAsync
//   used to be freed by its owner while still armed (heap-use-after-free when it
//   fired, every run under ASan), and an awaited one on a worker could be freed
//   while the loop was still inside its completion (TSan, every run).
import { sleepAsync } from "std/core/promise";

async function tick(n: int32): Promise<int32> {
	await sleepAsync(1);
	return n;
}

async function run(): Promise<void> {
	sleepAsync(20);
	const dropped = spawn(() => { sleepAsync(20); return 1; });
	const blocking = spawn(() => { await sleepAsync(1); return 2; });
	const stepped = [spawn(() => { return await tick(3); }), spawn(() => { return await tick(4); })];
	let sum = (await dropped) + (await blocking);
	for (const h of stepped) sum += await h;
	await sleepAsync(60);
	console.log(`worker timers ${sum}`);
	await Promise.race([sleepAsync(1), sleepAsync(40)]);
	console.log("loop race 1");
}

run();
