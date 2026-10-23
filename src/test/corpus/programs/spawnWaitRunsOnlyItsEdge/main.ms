// @stdout: main own=42 unrelated=2 held=true
// @stdout: task own=42 unrelated=2 held=true
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: `extern function` binds a C symbol, and JS has no pool to hold
// note: every pool worker is held, so the next two spawns stay queued, `unrelated` ahead of `own`; `unrelated` ends only after the waiter releases the workers, which it does only after `await own`. A waiter that ran any queued task took `unrelated` and waited on itself forever (old runtime: hang, killed by the timeout). The first phase waits on the loop thread. In the second, a pool task waits: the holders then hold from inside a wait (`await spawn`), so the worker count no longer counts them busy and the task's spawns are queued instead of run inline. A holder's own task may run on another worker instead of on its waiter, taking two threads, so holders are added one at a time until exactly one worker is left for the task.
@include("./pin.h");
import { cpuCount } from "std/os";
extern function pinHold(): int32;
extern function pinWaitAll(n: int32): void;
extern function pinReleaseAll(): void;
extern function pinReset(): void;
extern function pinRunningCount(): int32;
extern function pinEnterWait(): void;
extern function pinLeaveWait(): void;
extern function pinOccupied(): int32;

function race(): string {
	const unrelated = spawn(() => pinHold() + 1 as int32);
	const own = spawn(() => 42 as int32);
	const o = await own;
	pinReleaseAll();
	const u = await unrelated;
	return `own=${o} unrelated=${u}`;
}

function holdInWait(): int32 {
	pinEnterWait();
	const r = await spawn(() => pinHold());
	pinLeaveWait();
	return r;
}

function settle(held: Promise<int32>[]): boolean {
	let s: int32 = 0;
	for (const h of held) s += await h;
	return s == held.length;
}

const n = cpuCount();
const held: Promise<int32>[] = [];
for (let i = 0; i < n; i++) held.push(spawn(() => pinHold()));
pinWaitAll(n);
const onMain = race();
console.log(`main ${onMain} held=${settle(held)}`);

pinReset();
const heldInWait: Promise<int32>[] = [];
while (pinOccupied() < n - 1) {
	const running = pinRunningCount();
	if (pinOccupied() == n - 2 && heldInWait.length > 0) heldInWait.push(spawn(() => pinHold()));
	else heldInWait.push(spawn(() => holdInWait()));
	pinWaitAll(running + 1);
}
const inTask = spawn(() => race());
const onTask = await inTask;
console.log(`task ${onTask} held=${settle(heldInWait)}`);
