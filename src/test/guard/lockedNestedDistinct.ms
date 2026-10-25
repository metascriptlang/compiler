// GUARD-JS
// ULTRALOCK V7, the allowed side: a callback may enter a different cell, in
// either nesting order and through a callee, and may call plain helpers.
// RED MEANS: the holder check refuses a distinct cell, or the callback rule
// (refuseSuspendingLockCallback) refuses a callback that neither spawns nor
// awaits.

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Counter { n: int32; }

function inc(n: int32): int32 { return n + 1; }

function readOther(b: Locked<Counter>): int32 { return lockedRead(b, (w: Counter): int32 => w.n); }

function main(): void {
	const a: Locked<Counter> = new Locked({ n: 0 });
	const b: Locked<Counter> = new Locked({ n: 10 });
	for (let i = 0; i < 3; i = i + 1) {
		lockedUpdate(a, (v: Counter): Counter => {
			lockedUpdate(b, (w: Counter): Counter => ({ n: inc(w.n) }));
			return { n: v.n + readOther(b) };
		});
		lockedUpdate(b, (w: Counter): Counter => ({ n: w.n + lockedRead(a, (v: Counter): int32 => [v.n].map((x: int32): int32 => x)[0]) - lockedRead(a, (v: Counter): int32 => v.n) }));
	}
	const na = lockedRead(a, (v: Counter): int32 => v.n);
	const nb = lockedRead(b, (w: Counter): int32 => w.n);
	if (na != 36 || nb != 13) throw new Error("GUARD RED: a=" + na + " b=" + nb);
	console.log("GUARD-OK");
}

main();
