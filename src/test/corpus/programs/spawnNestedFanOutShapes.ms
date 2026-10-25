// @stdout: all=1296 arr=1296 lit=2187 slot=4096 async=1024
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait nests
// note: nested spawn trees whose waits outnumber the workers, one per await shape: Promise.all over an array, awaits over an array of handles, Promise.all over a literal, two handles awaited in turn, and an async function between levels. A waiter runs only the queued tasks its await depends on (the handle, the combinator's inputs, the future the async function is suspended on, and the tasks they join), so every tree completes without a waiter running unrelated work.
function viaAll(depth: int32): int32 {
	if (depth == 0) return 1;
	const kids: Promise<int32>[] = [];
	for (let i = 0; i < 6; i++) kids.push(spawn(() => viaAll(depth - 1)));
	const rs = await Promise.all(kids);
	let s: int32 = 0;
	for (const r of rs) s += r;
	return s;
}

function viaArr(depth: int32): int32 {
	if (depth == 0) return 1;
	const kids: Promise<int32>[] = [];
	for (let i = 0; i < 6; i++) kids.push(spawn(() => viaArr(depth - 1)));
	let s: int32 = 0;
	for (const k of kids) s += await k;
	return s;
}

function viaLit(depth: int32): int32 {
	if (depth == 0) return 1;
	const rs = await Promise.all([spawn(() => viaLit(depth - 1)), spawn(() => viaLit(depth - 1)), spawn(() => viaLit(depth - 1))]);
	return rs[0] + rs[1] + rs[2];
}

function viaSlot(depth: int32): int32 {
	if (depth == 0) return 1;
	const a = spawn(() => viaSlot(depth - 1));
	const b = spawn(() => viaSlot(depth - 1));
	return await a + await b;
}

async function pair(depth: int32): Promise<int32> {
	const a = spawn(() => viaAsync(depth - 1));
	const b = spawn(() => viaAsync(depth - 1));
	return await a + await b;
}

function viaAsync(depth: int32): int32 {
	if (depth == 0) return 1;
	return await pair(depth);
}

console.log(`all=${viaAll(4)} arr=${viaArr(4)} lit=${viaLit(7)} slot=${viaSlot(12)} async=${viaAsync(10)}`);
