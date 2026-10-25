// @stdout: locked caught destroyed=2 plain=2
// @stdout: fallible caught calls=4
// @stdout: field caught calls=2
// @stdout: normal exit calls=2
// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a destroy hook whose callees can throw runs its whole body while a throw unwinds the scope (old compiler: each callee that can throw returned at once, because the hook ran with the exception in flight: destroyed=0, calls=2 and calls=1)
import { lockedUpdate, lockedRead } from "std/core/promise";

const dead: Locked<int32> = new Locked<int32>(0);
let plain: int32 = 0;
let calls: int32 = 0;

function bump(): void {
	calls += 1;
	if (calls > 1000) throw new Error("never");
}

class Counted {
	v: int32;
	constructor(v: int32) { this.v = v; }
}
function onDestroy(this x: Counted): void {
	plain += 1;
	lockedUpdate(dead, (n: int32): int32 => n + 1);
}

class Bumps {
	v: int32;
	constructor(v: int32) { this.v = v; }
}
function onDestroy(this x: Bumps): void { bump(); bump(); }

class Holder {
	inner: Bumps;
	constructor(v: int32) { this.inner = new Bumps(v); }
}

function lockedScope(): int32 {
	const a = new Counted(0);
	const b = new Counted(1);
	if (b.v > 0) throw new Error("locked");
	return a.v;
}

function fallibleScope(): int32 {
	const a = new Bumps(0);
	const b = new Bumps(1);
	if (b.v > 0) throw new Error("fallible");
	return a.v;
}

function fieldScope(): int32 {
	const h = new Holder(1);
	if (h.inner.v > 0) throw new Error("field");
	return 0;
}

function normalScope(): int32 {
	const a = new Bumps(2);
	return a.v;
}

try { lockedScope(); } catch (e) { console.log(`locked caught destroyed=${lockedRead(dead, (n: int32): int32 => n)} plain=${plain}`); }
try { fallibleScope(); } catch (e) { console.log(`fallible caught calls=${calls}`); }
calls = 0;
try { fieldScope(); } catch (e) { console.log(`field caught calls=${calls}`); }
calls = 0;
normalScope();
console.log(`normal exit calls=${calls}`);
