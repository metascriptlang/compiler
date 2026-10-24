// GUARD-JS
// ULTRALOCK V7: a lockedUpdate/lockedRead callback runs while the cell is held,
// so it does not spawn or await, directly, through a callee at any depth, or
// through a function value; a sync-context await counts. Each shape is a
// compile error naming the call, on C and on JS.
// RED MEANS: refuseSuspendingLockCallback (checker/sendable.ms) lost a shape,
// or the Suspends effect in checker/effects.ms no longer reaches it.
//
// GUARD-CHECK-FAIL the callback of 'lockedUpdate' runs while the Locked cell is held
// GUARD-CHECK-FAIL but it awaits at 33:
// GUARD-CHECK-FAIL but it spawns at 34:
// GUARD-CHECK-FAIL but it calls 'waits' at 35:
// GUARD-CHECK-FAIL but it calls 'deep1' at 36:
// GUARD-CHECK-FAIL but it calls a function value at 37:
// GUARD-CHECK-FAIL but it calls 'waits' at 38:
// GUARD-CHECK-FAIL but it calls 'waits' at 27:
// GUARD-CHECK-FAIL but it spawns at 28:
// GUARD-CHECK-FAIL but it is a function value at 29:

import { lockedUpdate, lockedRead } from "std/core/promise";

function one(): int32 { return 1; }
function waits(): int32 { return await spawn(() => one()); }
function deep2(): int32 { return waits(); }
function deep1(): int32 { return deep2(); }
let hook: () => int32 = (): int32 => 2;
function named(v: int32): int32 { return v + waits(); }
const bound = (v: int32): int32 => { const f = spawn(() => one()); await f; return v; };
function viaParam(c: Locked<int32>, f: (v: int32) => int32): void { lockedUpdate(c, f); } // GUARD-REFUSED

function main(): void {
	const c: Locked<int32> = new Locked<int32>(0);
	lockedUpdate(c, (v: int32): int32 => v + await spawn(() => one())); // GUARD-REFUSED
	lockedUpdate(c, (v: int32): int32 => { const f = spawn(() => one()); await f; return v; }); // GUARD-REFUSED
	lockedUpdate(c, (v: int32): int32 => v + waits()); // GUARD-REFUSED
	lockedUpdate(c, (v: int32): int32 => v + deep1()); // GUARD-REFUSED
	lockedUpdate(c, (v: int32): int32 => v + hook()); // GUARD-REFUSED
	console.log(lockedRead(c, (v: int32): int32 => v + waits())); // GUARD-REFUSED
	lockedUpdate(c, named); // GUARD-REFUSED
	lockedUpdate(c, bound); // GUARD-REFUSED
	viaParam(c, (v: int32): int32 => v);
}

main();
