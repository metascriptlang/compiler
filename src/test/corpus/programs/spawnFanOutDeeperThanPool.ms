// @stdout: depth=64 all=1 async=1 handle=1
// @stdout: depth=256 all=1 async=1 handle=1
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait nests
// note: chains of nested waits far deeper than the worker count, one per edge form: Promise.all inputs, an async function suspended on a spawn, and a handle. Each waiter runs the queued task its await depends on, so the chain needs no thread beyond the pool; starting a thread per blocked waiter instead ran past the 64-thread limit and aborted.
function viaAll(d: int32): int32 {
	if (d == 0) return 1;
	const kids: Promise<int32>[] = [];
	kids.push(spawn(() => viaAll(d - 1)));
	kids.push(spawn(() => 0 as int32));
	const rs = await Promise.all(kids);
	return rs[0] + rs[1];
}

async function step(d: int32): Promise<int32> {
	const r = await spawn(() => viaAsync(d - 1));
	return r;
}

function viaAsync(d: int32): int32 {
	if (d == 0) return 1;
	return await step(d);
}

function viaHandle(d: int32): int32 {
	if (d == 0) return 1;
	const h = spawn(() => viaHandle(d - 1));
	const z = spawn(() => 0 as int32);
	return await h + await z;
}

for (const depth of [64 as int32, 256 as int32]) {
	console.log(`depth=${depth} all=${viaAll(depth)} async=${viaAsync(depth)} handle=${viaHandle(depth)}`);
}
