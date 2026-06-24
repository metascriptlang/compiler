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
