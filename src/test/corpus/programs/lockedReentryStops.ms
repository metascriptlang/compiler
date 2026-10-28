// @exit: 1
// @stdout: before 1
// @stdout: Error: unreachable: lockedRead re-entered a Locked cell that this thread already holds
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: ULTRALOCK V7 — a lockedUpdate callback that reads its own cell again stops the program with the operation's name instead of waiting on itself, and a catch around it cannot keep the program going. Sibling: lockedReentryThroughCalleeStops (lockedUpdate entered from a lockedRead, one call deeper through an alias).

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Counter { n: int32; }

function main(): void {
	const s: Locked<Counter> = new Locked({ n: 1 });
	console.log("before " + lockedRead(s, (v: Counter): int32 => v.n));
	try {
		lockedUpdate(s, (v: Counter): Counter => ({ n: v.n + lockedRead(s, (w: Counter): int32 => w.n) }));
	} catch (e) {
		console.log("caught " + e.message);
	}
	console.log("kept going");
}

main();
