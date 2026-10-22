// @stdout: throw left done=2
// @stdout: callee throw left done=2
// @stdout: return left done=2
// @stdout: async throw left done=2
// @stdout: awaited sum=1999970
// @stdout: churn ok
// @serial
// @skip-js: spawn on JS is a microtask that starts after the routine has left, and the JS backend has no exit join for held handles yet: lowerHeldSpawns runs for C only
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: handles kept in a local array join at every exit of the routine that spawned them, as a bare `const h = spawn(...)` does (spawnJoinsAtEveryExit): a throw, a throw from a nested call, a return, an async routine's throw, and handles pushed from a nested loop. Each task counts itself started and the routine leaves only after both started, so both are running at the exit; the caller reads the done count right after the routine has left, so done=2 means the exit joined both (old compiler: done=0 or 1, or a use-after-free once the churn reuses the cells).

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Count { started: int32; done: int32; }

class Child {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

class Holder {
	child: Child;
	constructor(c: Child) { this.child = c; }
}

function task(obj: Readonly<Holder>, s: Locked<Count>): int32 {
	lockedUpdate(s, (c: Count): Count => { return { started: c.started + 1, done: c.done }; });
	let sum: int32 = 0;
	for (let r = 0; r < 2000000; r += 1) sum = (sum + obj.child.v) % 1000003;
	lockedUpdate(s, (c: Count): Count => { return { started: c.started, done: c.done + 1 }; });
	return sum;
}

function waitStarted(s: Locked<Count>, n: int32): void {
	while (lockedRead(s, (c: Count): int32 => { return c.started; }) < n) {}
}

function doneCount(s: Locked<Count>): int32 {
	return lockedRead(s, (c: Count): int32 => { return c.done; });
}

function fresh(): Locked<Count> {
	return new Locked({ started: 0, done: 0 });
}

function fail(n: int32): int32 {
	if (n > 0) { throw "callee"; }
	return n;
}

function failDeep(n: int32): int32 {
	return fail(n) + 1;
}

function churn(): int32 {
	let t: int32 = 0;
	for (let i = 0; i < 200000; i += 1) {
		const h = new Holder(new Child(i % 7));
		t = (t + h.child.v) % 1000003;
	}
	return t;
}

function leaveByThrow(s: Locked<Count>): int32 {
	const obj = new Holder(new Child(3));
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < 2; k += 1) hs.push(spawn(() => task(obj, s)));
	waitStarted(s, 2);
	if (obj.child.v > 0) { throw "throw"; }
	let t: int32 = 0;
	for (const h of hs) { t = t + await h; }
	return t;
}

function leaveByCalleeThrow(s: Locked<Count>): int32 {
	const obj = new Holder(new Child(3));
	const hs: Promise<int32>[] = [];
	let k: int32 = 0;
	while (k < 2) {
		for (let j = 0; j < 1; j += 1) hs.push(spawn(() => task(obj, s)));
		k += 1;
	}
	waitStarted(s, 2);
	const n = failDeep(obj.child.v);
	let t: int32 = n;
	for (const h of hs) { t = t + await h; }
	return t;
}

function leaveByReturn(s: Locked<Count>): int32 {
	const obj = new Holder(new Child(3));
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < 2; k += 1) hs.push(spawn(() => task(obj, s)));
	waitStarted(s, 2);
	if (obj.child.v > 0) { return -1; }
	let t: int32 = 0;
	for (const h of hs) { t = t + await h; }
	return t;
}

async function leaveAsyncByThrow(s: Locked<Count>): Promise<int32> {
	const obj = new Holder(new Child(3));
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < 2; k += 1) hs.push(spawn(() => task(obj, s)));
	waitStarted(s, 2);
	if (obj.child.v > 0) { throw "async throw"; }
	const rs = await Promise.all(hs);
	return rs[0] + rs[1];
}

function awaitedAll(s: Locked<Count>): int32 {
	const obj = new Holder(new Child(3));
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < 2; k += 1) hs.push(spawn(() => task(obj, s)));
	let t: int32 = 0;
	for (const h of hs) { t = t + await h; }
	return t;
}

let total: int32 = 0;
const s1 = fresh();
try { total = leaveByThrow(s1); } catch (e) { console.log(`throw left done=${doneCount(s1)}`); }
total = total + churn();
const s2 = fresh();
try { total = total + leaveByCalleeThrow(s2); } catch (e) { console.log(`callee throw left done=${doneCount(s2)}`); }
total = total + churn();
const s3 = fresh();
total = total + leaveByReturn(s3);
console.log(`return left done=${doneCount(s3)}`);
total = total + churn();
const s4 = fresh();
try { total = total + await leaveAsyncByThrow(s4); } catch (e) { console.log(`async throw left done=${doneCount(s4)}`); }
total = total + churn();
const s5 = fresh();
console.log(`awaited sum=${awaitedAll(s5)}`);
total = total + churn();
console.log(total > 0 ? "churn ok" : "churn lost");
