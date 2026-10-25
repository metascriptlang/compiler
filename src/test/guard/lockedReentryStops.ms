// GUARD-JS
// ULTRALOCK V7: a lock callback that enters its own cell again, directly or
// through an alias and a callee, stops with an error naming the operation
// instead of waiting on itself. The cell stays usable afterwards: the holder is
// cleared and the lock released on the throw path.
// RED MEANS: the holder check in lockedUpdate/lockedRead (std/core/promise) or
// the holder store in runtime/promise/locked.h is gone; on C the deadlock is cut
// by the alarm below and the guard exits by signal.

import { lockedUpdate, lockedRead } from "std/core/promise";

when (c) {
	@include("runtime/os.h");
	extern function alarm(seconds: uint32): uint32 from "alarm";
}

struct Counter { n: int32; }

function peek(t: Locked<Counter>): int32 { return lockedRead(t, (w: Counter): int32 => w.n); }

function bump(t: Locked<Counter>): void { lockedUpdate(t, (w: Counter): Counter => ({ n: w.n + 100 })); }

function stops(label: string, f: () => void): void {
	try {
		f();
	} catch (e) {
		if (e.message.indexOf("re-entered a Locked cell that this thread already holds") < 0) throw new Error("GUARD RED: " + label + " threw " + e.message);
		console.log(label + ": " + e.message);
		return;
	}
	throw new Error("GUARD RED: " + label + " did not stop");
}

function main(): void {
	when (c) { alarm(20); }
	const s: Locked<Counter> = new Locked({ n: 1 });
	const alias = s;
	stops("read in update", (): void => { lockedUpdate(s, (v: Counter): Counter => ({ n: v.n + lockedRead(s, (w: Counter): int32 => w.n) })); });
	stops("alias and callee", (): void => { lockedUpdate(s, (v: Counter): Counter => ({ n: v.n + peek(alias) })); });
	stops("update in read", (): void => { lockedRead(s, (v: Counter): int32 => { bump(alias); return v.n; }); });
	lockedUpdate(s, (v: Counter): Counter => ({ n: v.n + 1 }));
	const n = lockedRead(s, (v: Counter): int32 => v.n);
	if (n != 2) throw new Error("GUARD RED: n=" + n);
	console.log("GUARD-OK");
}

main();
