// @maxrss: 20
// @stdout: locked total=480000
// @serial
// @skip-js: Locked<T> is a C-backend cell (atomic rc + inline ticket lock); no js binding
// note: Locked<T> shared across spawn — the one sanctioned shared-mutable-state pattern (PARALOCK Amendment I). ONE allocation holds the atomic refcount, the inline ticket lock and the typed payload, so the handle IS the atomic reference and needs no second wrapper; the payload is reachable only inside lockedUpdate/lockedRead, which ARE the critical section. 120000 rounds x 4 spawn tasks hammer one shared cell; total=480000 (120000x4) proves the ticket lock serializes the read-modify-write race-free, flat RSS proves the cell frees once, clean under drc+orc. Replaces the old Arc<struct{lock: Locker}> composition, which needed two allocations with two refcounts of different atomicity (the mixed-rc shape the sendable-pointee rule now rejects) and could only hold one untyped double. Bound 30-to-20 + rounds 3000-to-120000 (2026-09-04 RSS audit): the old shape was blind under 8.7KB/round (35MB slack over 3k rounds); measured steady-state is ~8MB (Linux drc), so 20 keeps 2.3x platform headroom while a spawn-machinery leak of ~64B/spawn x 480k spawns (~30MB) now trips. Bound 30→20 + rounds 3000→120000 (2026-09-04 RSS audit): the old shape was blind under 8.7KB/round (35MB slack over 3k rounds); the measured steady-state is ~8MB (Linux drc), so 20 keeps 2.3x platform headroom while a spawn-machinery leak of ~64B/spawn x 480k spawns (~30MB) now trips.

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Counter { n: int32; }

function bump(s: Locked<Counter>): Locked<Counter> {
	lockedUpdate(s, (v: Counter): Counter => { return { n: v.n + 1 }; });
	return s;
}

function main(): void {
	const s: Locked<Counter> = new Locked({ n: 0 });
	for (let round = 0; round < 120000; round = round + 1) {
		const h1 = spawn(() => bump(s));
		const h2 = spawn(() => bump(s));
		const h3 = spawn(() => bump(s));
		const h4 = spawn(() => bump(s));
		await h1; await h2; await h3; await h4;
	}
	const fin = lockedRead(s, (v: Counter): int32 => { return v.n; });
	console.log(`locked total=${fin}`);
}

main();
