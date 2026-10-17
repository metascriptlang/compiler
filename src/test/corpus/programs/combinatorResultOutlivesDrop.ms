// @stdout: dropped settled
// @stdout: race 7
// @stdout: race rejected
// @stdout: all 3
// @stdout: all rejected
// @stdout: any 5
// @stdout: allSettled done
// @serial
// @ledger-slack(Error): 153
// @xfail(raiser): raiser runtime error: Unknown host function: msPromiseRace (no host bridge registers it in hostTable.ms)

// note: A combinator keeps its result future alive until its last input has settled,
//   whether or not the caller kept the result. A dropped race/all/any/allSettled result
//   used to be freed by the caller while its inputs were pending, and the next input to
//   settle completed freed memory (heap-use-after-free every run under ASan).
//   The Error slack is the rejections nothing awaits: a failed future never releases
//   its error (inbox 2026-10-06-catch-handler-never-destroys-the-error).
import { sleepAsync } from "std/core/promise";

async function value(n: int32, ms: int32): Promise<int32> {
	await sleepAsync(ms);
	return n;
}

async function fail(ms: int32): Promise<int32> {
	await sleepAsync(ms);
	throw new Error("no");
}

async function run(): Promise<void> {
	for (let i = 0; i < 50; i++) {
		Promise.race([value(1, 1), fail(2)]);
		Promise.all([value(1, 1), value(2, 2)]);
		Promise.any([fail(1), value(2, 2)]);
		Promise.allSettled([value(1, 1), fail(2)]);
	}
	await sleepAsync(30);
	console.log("dropped settled");
	const r = await Promise.race([value(7, 1), fail(20)]);
	console.log(`race ${r}`);
	try {
		await Promise.race([fail(1), value(1, 20)]);
	} catch (e) {
		console.log("race rejected");
	}
	const a = await Promise.all([value(1, 1), value(2, 2)]);
	console.log(`all ${a[0] + a[1]}`);
	try {
		await Promise.all([fail(1), value(2, 20)]);
	} catch (e) {
		console.log("all rejected");
	}
	const y = await Promise.any([fail(1), value(5, 2)]);
	console.log(`any ${y}`);
	await Promise.allSettled([value(1, 1), fail(2)]);
	console.log("allSettled done");
	await sleepAsync(40);
}

run();
