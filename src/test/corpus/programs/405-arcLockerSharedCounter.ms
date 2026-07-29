// @maxrss: 30
// @stdout: arc-locker total=12000
// @serial
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Arc<struct{lock}> shared across spawn — the shipped shared-mutable-state pattern. Arc keeps the heap cell alive race-free (atomic rc); the bare Locker ticket lock serializes the read-modify-write. 3000 rounds × 4 spawn tasks hammer one shared Arc<Shared>; the counter lives in the lock's own slot, mutated ONLY inside withLock. total=12000 (3000×4) proves the ticket lock serializes race-free; flat RSS proves box+lock free once; clean under drc+orc. Replaces the dropped typed inline Mutex<T> (std/core/sync) — a redundant composition: Locker (exclusion) + Arc (cross-thread liveness) + struct (typed data) are orthogonal and compose without a dedicated lock-owns-data primitive, which MS can't make safe anyway (no field privacy / borrow checker to enforce no-unlocked-access). The sizeof-T-monomorphizes fix it was built on stays (general fix with its own regression).

import { Locker, createLocker, withLock, lockerGet, lockerSet } from "std/core/promise";

struct Shared { lock: Locker; }

function bump(s: Arc<Shared>): Arc<Shared> {
	withLock(s.lock, () => {
		const cur = lockerGet(s.lock);
		lockerSet(s.lock, cur + 1);
	});
	return s;
}

function main(): void {
	const s: Arc<Shared> = new Arc({ lock: createLocker() });
	withLock(s.lock, () => { lockerSet(s.lock, 0); });
	for (let round = 0; round < 3000; round = round + 1) {
		const h1 = spawn(() => bump(s));
		const h2 = spawn(() => bump(s));
		const h3 = spawn(() => bump(s));
		const h4 = spawn(() => bump(s));
		await h1; await h2; await h3; await h4;
	}
	let fin = 0;
	withLock(s.lock, () => { fin = lockerGet(s.lock) as int32; });
	console.log(`arc-locker total=${fin}`);
}
