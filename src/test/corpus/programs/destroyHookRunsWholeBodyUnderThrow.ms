// @stdout: locked caught destroyed=2 plain=2
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table (the installed unplaced build stops at the same 'new')
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a destroy hook that updates a Locked cell runs its whole body while a throw unwinds the scope (old compiler: the update returned at once, because the hook ran with the exception in flight: destroyed=0)
import { lockedUpdate, lockedRead } from "std/core/promise";

const dead: Locked<int32> = new Locked<int32>(0);
let plain: int32 = 0;

class Counted {
	v: int32;
	constructor(v: int32) { this.v = v; }
}
function onDestroy(this x: Counted): void {
	plain += 1;
	lockedUpdate(dead, (n: int32): int32 => n + 1);
}

function lockedScope(): int32 {
	const a = new Counted(0);
	const b = new Counted(1);
	if (b.v > 0) throw new Error("locked");
	return a.v;
}

try { lockedScope(); } catch (e) { console.log(`locked caught destroyed=${lockedRead(dead, (n: int32): int32 => n)} plain=${plain}`); }
