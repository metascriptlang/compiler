// @stdout: ok=true
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS has no pool, so no waiter reads another task's frame
// note: pool tasks call async functions that spawn joined children and suspend before joining them, one per form: handles kept in an array, two handles, and `await Promise.all([spawn, spawn])`, which submits a spawn group from inside the async step. A waiter may run a queued task that a running task of its await joins, found through the task's ancestors on the running threads' stacks; an async step returns while its children are still queued, so they are submitted with no ancestor. Before that, the group's children named the calling task's frame after it had returned (SAN lane: stack-use-after-return in msPoolTaskIn, 3 of 3 runs).
import { sleepAsync } from "std/core/promise";

function work(n: int32): int32 {
	let x: int32 = 0;
	for (let i: int32 = 0; i < n; i++) x = (x * 31 + i) % 1000003;
	return x % 2 + 1;
}

// Spawns joined children, suspends before joining them, resumes on its owner later.
async function viaGroup(): Promise<int32> {
	const kids: Promise<int32>[] = [];
	kids.push(spawn(() => work(200000)));
	kids.push(spawn(() => work(200000)));
	await sleepAsync(2);
	const rs = await Promise.all(kids);
	return rs[0] + rs[1];
}

// The group form: its children are submitted to the pool from inside the stepper,
// which then suspends on the group instead of blocking.
async function viaLiteral(): Promise<int32> {
	const rs = await Promise.all([spawn(() => work(200000)), spawn(() => work(200000))]);
	return rs[0] + rs[1];
}

async function viaHandles(): Promise<int32> {
	const a = spawn(() => work(200000));
	const b = spawn(() => work(200000));
	await sleepAsync(2);
	return await a + await b;
}

function task(): int32 {
	viaGroup();
	viaHandles();
	viaLiteral();
	return 1;
}

function tree(d: int32): int32 {
	if (d == 0) return work(20000);
	const a = spawn(() => tree(d - 1));
	const b = spawn(() => tree(d - 1));
	return await a + await b;
}

let s: int32 = 0;
for (let round = 0; round < 20; round++) {
	const hs: Promise<int32>[] = [];
	for (let i = 0; i < 32; i++) hs.push(spawn(() => task()));
	const t = spawn(() => tree(8));
	for (const h of hs) s += await h;
	s += await t;
}
console.log(`ok=${s > 0}`);
