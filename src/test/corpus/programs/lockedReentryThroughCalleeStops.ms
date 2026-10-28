// @exit: 1
// @stdout: before 1
// @stdout: Error: unreachable: lockedUpdate re-entered a Locked cell that this thread already holds
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: ULTRALOCK V7 — a lockedRead callback that reaches the same cell through an alias and a callee's lockedUpdate stops the program with the operation's name instead of waiting on itself, and a catch around it cannot keep the program going. Sibling: lockedReentryStops (lockedRead entered directly from a lockedUpdate).

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Counter { n: int32; }

function bump(t: Locked<Counter>): void { lockedUpdate(t, (w: Counter): Counter => ({ n: w.n + 100 })); }

function main(): void {
	const s: Locked<Counter> = new Locked({ n: 1 });
	const alias = s;
	console.log("before " + lockedRead(s, (v: Counter): int32 => v.n));
	try {
		lockedRead(s, (v: Counter): int32 => { bump(alias); return v.n; });
	} catch (e) {
		console.log("caught " + e.message);
	}
	console.log("kept going");
}

main();
