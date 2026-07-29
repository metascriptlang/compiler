// @maxrss: 30
// @stdout: map-guard-fatal armed
// @exit: 2
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Negative half of the Map/Set concurrent-access guard (#188). After a clean set, forces the `writing` flag true (simulating a concurrent writer mid-mutation) then reads — get() detects writing and calls msMapFatal, which prints `fatal error: concurrent map read and map write` and exit(2) UNRECOVERABLE (Go fatal model: a detected race may already have corrupted memory, so it must not be a catchable throw). expectExit:2 asserts the fail-loud actually fired (the 'armed' marker prints before it; SHOULD-NOT-REACH never does). Locks the guard in CI so a future refactor can't silently disable it.

import { Map } from "std/core/struct";

function main(): void {
	const m = new Map<int32, int32>();
	m.set(1 as int32, 10 as int32);
	console.log("map-guard-fatal armed");
	m.writing = true;
	const v = m.get(1 as int32);
	console.log(`SHOULD-NOT-REACH ${v}`);
}
main();
