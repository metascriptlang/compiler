// @stdout: direct true
// @stdout: nested true
// @stdout: outside 9
// @stdout: view 5
// @xfail(raiser): the Raiser VM has no spawn pool threads or Locked cell, which this program pins (no host bridge for msLockedHeldHere/msLockedAcquire, and Locked has no constructor)
// @serial
// @skip-js: Locked is native only
// note: a spawn thunk passes a captured Sendable closure, or a captured cyclic cell, to a callee that calls a function value. The capture is a const field of the thunk's env, so the thunk reads it in place and takes no count: a count taken on the worker rooted the parent's cell in the worker's root set and the parent freed it ("M1 owner violation at free"). Per-iteration env, function-level env and a class capture.

type Handler = Sendable<(worker: int32, n: int32) => int32>;
type Slot = Sendable<(n: int32) => int32>;

function onWorker(handler: Handler, worker: int32): Slot {
	return (n: int32): int32 => handler(worker, n);
}

function loop(n: int32, slot: Slot, admission: Locked<int32>): int32 {
	return slot(n);
}

function serve(handler: Handler, workers: int32): Result<void, string> {
	const admission: Locked<int32> = new Locked(0);
	const running: Promise<int32>[] = [];
	for (let worker = 2; worker <= workers; worker++) {
		const slot = onWorker(handler, worker);
		const id = worker;
		running.push(spawn(() => loop(id, slot, admission)));
	}
	const own = loop(1, onWorker(handler, 1), admission);
	const stopped = await Promise.all(running);
	return Result.ok(null);
}

function serveOutsideLoop(handler: Handler): int32 {
	const admission: Locked<int32> = new Locked(0);
	const slot = onWorker(handler, 2);
	const running: Promise<int32>[] = [];
	for (let k = 0; k < 3; k++) {
		const id = k;
		running.push(spawn(() => loop(id, slot, admission)));
	}
	const done = await Promise.all(running);
	return done[0] + done[1] + done[2];
}

class Counter {
	base: int32;
	peer: Counter | null = null;
	constructor(base: int32) { this.base = base; }
}

function viewLoop(n: int32, counter: Readonly<Counter>, slot: Slot): int32 {
	return slot(n) + counter.base;
}

function serveClassView(handler: Handler): int32 {
	const counter = new Counter(1);
	counter.peer = counter;
	const slot = onWorker(handler, 1);
	const first = spawn(() => viewLoop(0, counter, slot));
	const second = spawn(() => viewLoop(1, counter, slot));
	return (await first) + (await second);
}

function main(): int32 {
	const handler: Handler = (worker: int32, n: int32): int32 => worker + n;
	const served = serve(handler, 4);
	console.log(`direct ${served.ok}`);
	const serving = spawn(() => serve(handler, 4));
	const nested = await serving;
	console.log(`nested ${nested.ok}`);
	console.log(`outside ${serveOutsideLoop(handler)}`);
	console.log(`view ${serveClassView(handler)}`);
	return 0;
}

process.exit(main());
