// A value is not lent while code started before the lend can still change it
//
// INVARIANT (ULTRALOCK V4, V6): a partition reachable from a timer, a callback or a routine that is
//   still pending is not lendable. The lender waits at the await that closes the lend, and its loop
//   runs that code there while the actor or the task reads the value on another thread.
//
// WHAT IT CATCHES: a timer callback that writes the value, a `.then` callback that writes it, an async
//   routine called without await that writes its parameter after it suspends, a callee that arms a
//   timer over its parameter, and a callee that starts such an async routine; each before a lend to
//   an actor call or to a spawn.
//
// RED MEANS: the lender's thread writes a buffer while another thread reads it, or a push reallocates
//   it under the reader, and C and JS print different results.
//
// The legal neighbours are pinned by lendPendingWriterAccepts.ms, which must build and run.
//
// GUARD-JS
// GUARD-CHECK-FAIL 'timerArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'thenArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'asyncArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'armedArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'kickedArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'taskArr' is lent to the spawn
// GUARD-CHECK-FAIL 'taskTimerArr' is lent to the spawn

import { stop, ExitReason } from "std/actor";

actor Reader {
	watch(a: int32[]): int32 { return a[0] + a.length; }
}

function tick(): Promise<void> {
	return new Promise<void>((done) => { setTimeout(() => { done(); }, 0); });
}

async function poke(a: int32[]): Promise<void> {
	await tick();
	a[0] = 42;
}

function arm(a: int32[]): void {
	setTimeout(() => { a[0] = 42; }, 0);
}

function kick(a: int32[]): void {
	poke(a);
}

async function timer(r: Reader): Promise<int32> {
	const timerArr: int32[] = [1, 2, 3];
	setTimeout(() => { timerArr[0] = 42; }, 0);
	return await r.watch(timerArr); // GUARD-REFUSED
}

async function then(r: Reader): Promise<int32> {
	const thenArr: int32[] = [1, 2, 3];
	const poking = tick().then((): void => { thenArr.push(4); });
	const n = await r.watch(thenArr); // GUARD-REFUSED
	await poking;
	return n;
}

async function pendingAsync(r: Reader): Promise<int32> {
	const asyncArr: int32[] = [1, 2, 3];
	const poking = poke(asyncArr);
	const n = await r.watch(asyncArr); // GUARD-REFUSED
	await poking;
	return n;
}

async function armedByCallee(r: Reader): Promise<int32> {
	const armedArr: int32[] = [1, 2, 3];
	arm(armedArr);
	return await r.watch(armedArr); // GUARD-REFUSED
}

async function kickedByCallee(r: Reader): Promise<int32> {
	const kickedArr: int32[] = [1, 2, 3];
	kick(kickedArr);
	return await r.watch(kickedArr); // GUARD-REFUSED
}

async function task(): Promise<int32> {
	const taskArr: int32[] = [1, 2, 3];
	const poking = poke(taskArr);
	const n = await spawn((): int32 => taskArr[0]); // GUARD-REFUSED
	await poking;
	return n;
}

async function taskTimer(): Promise<int32> {
	const taskTimerArr: int32[] = [1, 2, 3];
	setTimeout(() => { taskTimerArr[0] = 42; }, 0);
	return await spawn((): int32 => taskTimerArr[0]); // GUARD-REFUSED
}

async function main(): Promise<void> {
	const r = new Reader();
	const t = await timer(r) + await then(r) + await pendingAsync(r) + await armedByCallee(r) + await kickedByCallee(r)
		+ await task() + await taskTimer();
	stop(r.pid, ExitReason.Normal);
	console.log(`t=${t}`);
}

await main();
