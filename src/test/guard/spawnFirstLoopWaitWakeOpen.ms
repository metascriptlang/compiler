// guard: the loop thread's first task wait opens its wake channel before a worker can wake it
//
// INVARIANT (ULTRALOCK T3, T4): a loop thread waiting on a task another thread runs keeps
//   pumping its loop and is woken through its wake channel when the task completes. The
//   channel exists before the waiter publishes that it waits in its loop, so the worker that
//   reads the flag and writes the wake is ordered after the channel's creation.
//
// SHAPE: the program's first wait, since only the first loop wait of a process opens the
//   channel. A worker takes the held task during the parent's 10 ms pause, so the wait cannot
//   run it; the task, which drops an acyclic moved capture, completes about 2 ms into the wait.
//   It must finish inside the first 5 ms loop pump: the waiter's next pass republishes the flag
//   after the channel exists, and a task completing after that pass is ordered behind it.
//   Measured on Linux arm64 TSan before the fix: 9 of 10 runs red.
//
// RED MEANS: ThreadSanitizer reports a data race between the wake write in msChannelWake on
//   the worker and the pipe that msLoopChannelOpen creates on the main thread.
//
// GUARD-TSAN

class Box { v: int32; constructor(v: int32) { this.v = v; } }

function spin(ms: number, b: Box): int32 {
	const until = Date.now() + ms;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + 1) % 1000;
	return n * 0 + b.v;
}

function main(): void {
	const b = new Box(1);
	const f = spawn(() => spin(12, b), { move: [b] });
	spin(10, new Box(0));
	const r = await f;
	if (r == 1) console.log("GUARD-OK");
	else process.exit(1);
}

main();
