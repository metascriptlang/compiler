// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native sync-context await
// @xfail(raiser): raiser runtime error: Unknown host function: msSpawn
// @serial
// @stdout: fused caught await timeout
// @stdout: group caught await timeout
// @stdout: Error: unhandled rejection: fused late failure
// @stdout: Error: unhandled rejection: group late failure
// @exit: 1
// note: a `{timeout}` await that expires joins its children before it throws `await timeout`; a child that fails after the deadline is observed only by that join, so its failure is an unhandled rejection reported at exit, exit 1 (ULTRALOCK T2), for the fused await and for a Promise.all group. The deadline is computed after the submit, so `startedThenZero` holds it until the child runs on a worker and then sets it to now: the wait times out at once while the child is still running (old compiler: the failure was dropped, exit 0).

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Flag { on: boolean; }

function late(s: Locked<Flag>, why: string): int32 {
	lockedUpdate(s, (f: Flag): Flag => { return { on: true }; });
	const t0 = Date.now();
	while (Date.now() - t0 < 300) {}
	throw new Error(why);
}

function startedThenZero(s: Locked<Flag>): int32 {
	while (!lockedRead(s, (f: Flag): boolean => { return f.on; })) {}
	return 0;
}

function fused(): string {
	const s: Locked<Flag> = new Locked({ on: false });
	try { return `v ${await spawn(() => late(s, "fused late failure"), { timeout: startedThenZero(s) })}`; } catch (e) { return "caught " + e.message; }
}

function group(): string {
	const s: Locked<Flag> = new Locked({ on: false });
	try {
		const rs = await Promise.all([spawn((): int32 => 1, { timeout: startedThenZero(s) }), spawn((): int32 => late(s, "group late failure"))]);
		return `v ${rs[0]}`;
	} catch (e) { return "caught " + e.message; }
}

console.log(`fused ${fused()}`);
console.log(`group ${group()}`);
