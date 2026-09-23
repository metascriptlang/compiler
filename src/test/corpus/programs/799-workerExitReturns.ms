// @xfail(raiser): runs but exits 0: process.exit inside a spawned task does not end the program there
// @exit: 3
// @serial
// @stdout: worker-exit armed 45
// note: process.exit on a pool worker ends the process with that code. Pre-fix on Windows: the pool's atexit shutdown ran on that worker and waited on its own thread handle forever (sibling: 798-workerMapFatalExits). A first awaited spawn starts the pool, and the main thread spins before awaiting, so a worker, not the help-first main thread, takes the task.

function spin(n: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) s = (s + i) % 1000;
	return s;
}

function quit(): int32 {
	process.exit(3);
	return 0;
}

console.log(`worker-exit armed ${await spawn(() => spin(10))}`);
const f = spawn(() => quit());
const s = spin(5000000);
console.log(`SHOULD-NOT-REACH ${await f + s}`);
