// A caller does not change what an awaited actor CALL borrows before it awaits the reply
//
// INVARIANT (ULTRALOCK V6, V4): a CALL carrying a BORROW lends the argument from its publication
//   until the await that consumes the reply. In that window the caller follows V4's parent-side
//   law for the lent partition: no write, move, destroy or escape, directly or through a callee;
//   a partition reachable from module state is not lendable. Each violation is a compile error
//   naming the call.
//
// WHAT IT CATCHES: an element write, a push, a field write, a write through an alias, a write
//   through a callee, a branch that skips the await and then writes, a module-level array lent to
//   the actor, a promise that leaves the frame that owns the argument before its await (pushed into the
//   caller's list, returned), and
//   a write while an async helper that awaits the actor call is still pending.
//
// RED MEANS: the sender writes a buffer the actor reads on another thread at the same time, or a
//   push reallocates it under the actor's reads, or the frame that owns the argument ends while the
//   actor still reads it.
//
// The legal neighbours are pinned by actorCallLendAccepts.ms, which must build and run.
//
// GUARD-JS
// GUARD-CHECK-FAIL 'writeArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'pushArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'fieldBox' is lent to the actor call of 'see'
// GUARD-CHECK-FAIL 'aliasArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'calleeArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'branchArr' is lent to the actor call of 'watch'
// GUARD-CHECK-FAIL 'moduleArr'
// GUARD-CHECK-FAIL the actor call of 'watch'
// GUARD-CHECK-FAIL 'asyncArr' is lent to the actor call of 'watch'

import { stop, ExitReason } from "std/actor";

class Box { v: int32 = 1; }

actor Reader {
	watch(a: int32[]): int32 { return a[0] + a.length; }
	see(b: Box): int32 { return b.v; }
}

const moduleArr: int32[] = [5];

function fill(a: int32[]): void { a[0] = 7; }

async function write(r: Reader): Promise<int32> {
	const writeArr: int32[] = [1, 2, 3];
	const p = r.watch(writeArr); // GUARD-REFUSED
	writeArr[0] = 42;
	return await p;
}

async function push(r: Reader): Promise<int32> {
	const pushArr: int32[] = [1, 2, 3];
	const p = r.watch(pushArr); // GUARD-REFUSED
	for (let k = 0; k < 1000; k += 1) pushArr.push(k);
	return await p;
}

async function field(r: Reader): Promise<int32> {
	const fieldBox = new Box();
	const p = r.see(fieldBox); // GUARD-REFUSED
	fieldBox.v = 2;
	return await p;
}

async function alias(r: Reader): Promise<int32> {
	const aliasArr: int32[] = [1];
	const other = aliasArr;
	const p = r.watch(aliasArr); // GUARD-REFUSED
	other[0] = 2;
	return await p;
}

async function callee(r: Reader): Promise<int32> {
	const calleeArr: int32[] = [1];
	const p = r.watch(calleeArr); // GUARD-REFUSED
	fill(calleeArr);
	return await p;
}

async function branch(r: Reader, c: boolean): Promise<int32> {
	const branchArr: int32[] = [1];
	const p = r.watch(branchArr); // GUARD-REFUSED
	let n: int32 = 0;
	if (c) n = await p;
	branchArr[0] = 3;
	return n;
}

async function fromModule(r: Reader): Promise<int32> {
	return await r.watch(moduleArr); // GUARD-REFUSED
}

function stored(r: Reader, ps: Promise<int32>[]): void {
	const storedArr: int32[] = [1];
	ps.push(r.watch(storedArr)); // GUARD-REFUSED
}

function returned(r: Reader): Promise<int32> {
	const returnedArr: int32[] = [1];
	return r.watch(returnedArr); // GUARD-REFUSED
}

async function relay(r: Reader, a: int32[]): Promise<int32> {
	return await r.watch(a);
}

async function viaAsync(r: Reader): Promise<int32> {
	const asyncArr: int32[] = [1];
	const p = relay(r, asyncArr); // GUARD-REFUSED
	asyncArr[0] = 4;
	return await p;
}

async function main(): Promise<void> {
	const r = new Reader();
	const ps: Promise<int32>[] = [];
	stored(r, ps);
	const t = await ps[0] + await write(r) + await push(r) + await field(r) + await alias(r) + await callee(r)
		+ await branch(r, true) + await fromModule(r) + await returned(r) + await viaAsync(r);
	stop(r.pid, ExitReason.Normal);
	console.log(`t=${t}`);
}

await main();
