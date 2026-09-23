// @xfail(raiser): raiser runtime error: attempt to access a nil address
// @exit: 2
// @serial
// @stdout: worker-map-fatal armed 45
// @skip-js: C-only by design. The `writing` flag is the C map's guard state; js binds Map to the native global, which has no such field.
// note: A map fatal raised on a pool worker ends the process with exit 2 and its message. Pre-fix on Windows: exit() ran the pool's atexit shutdown on that worker, which waited on its own thread handle forever, so the process sat at 0 CPU (sibling: 799-workerExitReturns). A first awaited spawn starts the pool, and the main thread spins before awaiting, so a worker, not the help-first main thread, takes the task.

import { Map } from "std/core/struct";

function spin(n: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) s = (s + i) % 1000;
	return s;
}

function corrupt(): int32 {
	const m = new Map<int32, int32>();
	m.set(1 as int32, 10 as int32);
	m.writing = true;
	return m.get(1 as int32) ?? 0;
}

console.log(`worker-map-fatal armed ${await spawn(() => spin(10))}`);
const f = spawn(() => corrupt());
const s = spin(5000000);
console.log(`SHOULD-NOT-REACH ${await f + s}`);
