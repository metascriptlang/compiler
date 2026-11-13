// The legal neighbours of lendPendingWriterRefuses.ms: a value is lent after the routine that
// writes it was awaited, while a pending routine only reads it, after a closure that writes it was
// only called, after a callback handed to a callee that runs it before returning, and before a timer
// that writes it is armed.
//
// INVARIANT (ULTRALOCK V4, V6): only code that can still run while the lender waits blocks a lend;
//   reads stay legal, and a writer that has finished or has not started yet blocks nothing.
//
// RED MEANS: the pending-writer rule refuses a lend nothing can race.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

actor Reader {
	watch(a: int32[]): int32 { return a[0] * 10 + a.length; }
}

function tick(): Promise<void> {
	return new Promise<void>((done) => { setTimeout(() => { done(); }, 0); });
}

async function poke(a: int32[]): Promise<void> {
	await tick();
	a[0] = 4;
}

async function peek(a: Readonly<int32[]>): Promise<int32> {
	await tick();
	return a[1];
}

async function awaitedFirst(r: Reader): Promise<int32> {
	const a: int32[] = [1, 2, 3];
	await poke(a);
	return await r.watch(a);
}

async function joinedFirst(r: Reader): Promise<int32> {
	const a: int32[] = [1, 2, 3];
	const poking = poke(a);
	await poking;
	return await r.watch(a);
}

async function pendingReader(r: Reader): Promise<int32> {
	const a: int32[] = [1, 2, 3];
	const peeking = peek(a);
	return await r.watch(a) + await peeking;
}

async function calledClosure(r: Reader): Promise<int32> {
	const a: int32[] = [1, 2, 3];
	const bump = (): void => { a[0] = 5; };
	bump();
	return await r.watch(a);
}

function each(xs: Readonly<int32[]>, visit: (x: int32) => void): void {
	for (const x of xs) visit(x);
}

async function ranCallback(r: Reader): Promise<int32> {
	const a: int32[] = [1, 2, 3];
	const source: int32[] = [6, 7];
	each(source, (x: int32): void => { a.push(x); });
	return await r.watch(a);
}

async function timerAfter(r: Reader): Promise<int32> {
	const a: int32[] = [1, 2, 3];
	const n = await r.watch(a);
	setTimeout(() => { a[0] = 9; }, 0);
	return n;
}

async function main(): Promise<void> {
	const r = new Reader();
	const a = await awaitedFirst(r);
	const b = await joinedFirst(r);
	const c = await pendingReader(r);
	const d = await calledClosure(r);
	const e = await ranCallback(r);
	const f = await timerAfter(r);
	stop(r.pid, ExitReason.Normal);
	console.log(`a=${a} b=${b} c=${c} d=${d} e=${e} f=${f}`);
	if (a == 43 && b == 43 && c == 15 && d == 53 && e == 15 && f == 13) console.log("GUARD-OK");
}

await main();
