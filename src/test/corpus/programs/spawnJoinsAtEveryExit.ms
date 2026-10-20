// @stdout: throw left done=true
// @stdout: return left done=true
// @stdout: break left done=true
// @stdout: callee throw left done=true
// @stdout: churn ok
// @serial
// @skip-js: spawn on JS is a microtask that starts after the scope has left, and an unawaited spawn has no join there (ULTRALOCK T2, JS row)
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: a scope left before it awaits its spawn (by throw, return, break or a callee's throw) waits for the task first, so the task never reads a capture the scope released. Each task marks a Locked flag when it starts and its scope leaves only after that, so the task is running at the exit; the caller reads `done` right after the scope has left, so done=true means the exit joined the task (old compiler: done=false, or a use-after-free once the churn reuses the cells, exit 134/138).

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

function fail(n: int32): int32 {
	if (n > 0) { throw "callee"; }
	return n;
}

function churn(): int32 {
	let t: int32 = 0;
	for (let i = 0; i < 200000; i += 1) {
		const h = new Holder(new Child(i % 7));
		t = (t + h.child.v) % 1000003;
	}
	return t;
}

function leaveByThrow(s: Locked<Flag>): int32 {
	const obj = new Holder(new Child(3));
	const f = spawn(() => task(obj, s));
	waitStarted(s);
	if (obj.child.v > 0) { throw "throw"; }
	return await f;
}

function leaveByReturn(s: Locked<Flag>): int32 {
	const obj = new Holder(new Child(3));
	const f = spawn(() => task(obj, s));
	waitStarted(s);
	if (obj.child.v > 0) { return -1; }
	return await f;
}

function leaveByBreak(s: Locked<Flag>): int32 {
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

function leaveByCalleeThrow(s: Locked<Flag>): int32 {
	const obj = new Holder(new Child(3));
	const f = spawn(() => task(obj, s));
	waitStarted(s);
	const n = fail(obj.child.v);
	return n + await f;
}

let total: int32 = 0;
const s1 = fresh();
try { total = leaveByThrow(s1); } catch (e) { console.log(`throw left done=${isDone(s1)}`); }
total = total + churn();
const s2 = fresh();
total = total + leaveByReturn(s2);
console.log(`return left done=${isDone(s2)}`);
total = total + churn();
const s3 = fresh();
total = total + leaveByBreak(s3);
console.log(`break left done=${isDone(s3)}`);
total = total + churn();
const s4 = fresh();
try { total = total + leaveByCalleeThrow(s4); } catch (e) { console.log(`callee throw left done=${isDone(s4)}`); }
total = total + churn();
console.log(total > 0 ? "churn ok" : "churn lost");
