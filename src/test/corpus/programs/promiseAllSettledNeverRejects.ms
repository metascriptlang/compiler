// @stdout: settled after both
// @stdout: empty settled
// note: Promise.allSettled completes once every input has settled, whether an input fulfilled or rejected, and an empty list completes at once.

import { sleepAsync } from "std/core/promise";

async function value(n: int32, ms: int32): Promise<int32> {
	await sleepAsync(ms);
	return n;
}

async function run(): Promise<void> {
	const rejected: Promise<int32> = Promise.reject(new Error("no"));
	await Promise.allSettled([value(1, 1), rejected]);
	console.log("settled after both");
	const none: Promise<int32>[] = [];
	await Promise.allSettled(none);
	console.log("empty settled");
}
run();
