// @stdout: switch throw left done=true
// @stdout: switch break left done=true
// @stdout: nested break left done=true
// @stdout: async return left done=true
// @stdout: async break left done=true
// @stdout: churn ok
// @serial
// @skip-js: spawn on JS is a microtask that starts after the scope has left, and an unawaited spawn has no join there (ULTRALOCK T2, JS row)
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: the exits spawnJoinsAtEveryExit does not take: a throw from a switch case, a break out of a switch case, a break out of an inner loop, and an async routine's return and break. Each task marks a Locked flag when it starts and the routine leaves only after that, so the task is running at the exit; the caller reads `done` right after the routine has left, so done=true means the exit joined the task (without the join: done=false, or a use-after-free once the churn reuses the cells).

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Flag { on: boolean; done: boolean; }

class Child {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

class Holder {
	child: Child;
	constructor(c: Child) { this.child = c; }
}

function task(obj: Readonly<Holder>, s: Locked<Flag>): int32 {
	lockedUpdate(s, (f: Flag): Flag => { return { on: true, done: false }; });
	let sum: int32 = 0;
	for (let r = 0; r < 2000000; r += 1) sum = (sum + obj.child.v) % 1000003;
	lockedUpdate(s, (f: Flag): Flag => { return { on: true, done: true }; });
	return sum;
}

function waitStarted(s: Locked<Flag>): void {
	while (!lockedRead(s, (f: Flag): boolean => { return f.on; })) {}
}

function isDone(s: Locked<Flag>): boolean {
	return lockedRead(s, (f: Flag): boolean => { return f.done; });
}

function fresh(): Locked<Flag> {
	return new Locked({ on: false, done: false });
}

function churn(): int32 {
	let t: int32 = 0;
	for (let i = 0; i < 200000; i += 1) {
		const h = new Holder(new Child(i % 7));
		t = (t + h.child.v) % 1000003;
	}
	return t;
}

function leaveSwitchByThrow(s: Locked<Flag>, k: int32): int32 {
	const obj = new Holder(new Child(3));
	let t: int32 = 0;
	switch (k) {
		case 1: {
			const f = spawn(() => task(obj, s));
			waitStarted(s);
			if (obj.child.v > 0) { throw "switch"; }
			t = await f;
			break;
		}
		default:
			t = 7;
	}
	return t;
}

function leaveSwitchByBreak(s: Locked<Flag>, k: int32): int32 {
	const obj = new Holder(new Child(3));
	let t: int32 = 0;
	switch (k) {
		case 1: {
			const f = spawn(() => task(obj, s));
			waitStarted(s);
			if (obj.child.v > 0) { break; }
			t = await f;
			break;
		}
		default:
			t = 7;
	}
	return t;
}

function leaveByNestedBreak(s: Locked<Flag>): int32 {
	const obj = new Holder(new Child(3));
	let t: int32 = 0;
	for (let i = 0; i < 1; i += 1) {
		for (let j = 0; j < 2; j += 1) {
			const f = spawn(() => task(obj, s));
			waitStarted(s);
			if (j == 0) { break; }
			t = t + await f;
		}
	}
	return t;
}

async function asyncLeaveByReturn(s: Locked<Flag>): Promise<int32> {
	const obj = new Holder(new Child(3));
	const f = spawn(() => task(obj, s));
	waitStarted(s);
	if (obj.child.v > 0) { return -1; }
	return await f;
}

async function asyncLeaveByBreak(s: Locked<Flag>): Promise<int32> {
	const obj = new Holder(new Child(3));
	let t: int32 = 0;
	for (let i = 0; i < 2; i += 1) {
		const f = spawn(() => task(obj, s));
		waitStarted(s);
		if (i == 0) { break; }
		t = t + await f;
	}
	return t;
}

async function main(): Promise<void> {
	let total: int32 = 0;
	const s1 = fresh();
	try { total = leaveSwitchByThrow(s1, 1); } catch (e) { console.log(`switch throw left done=${isDone(s1)}`); }
	total = total + churn();
	const s2 = fresh();
	total = total + leaveSwitchByBreak(s2, 1);
	console.log(`switch break left done=${isDone(s2)}`);
	total = total + churn();
	const s3 = fresh();
	total = total + leaveByNestedBreak(s3);
	console.log(`nested break left done=${isDone(s3)}`);
	total = total + churn();
	const s4 = fresh();
	total = total + await asyncLeaveByReturn(s4);
	console.log(`async return left done=${isDone(s4)}`);
	total = total + churn();
	const s5 = fresh();
	total = total + await asyncLeaveByBreak(s5);
	console.log(`async break left done=${isDone(s5)}`);
	total = total + churn();
	console.log(total > 0 ? "churn ok" : "churn lost");
}

main();
