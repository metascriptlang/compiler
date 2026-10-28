// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native worker rc ops
// @stdout: done 2 hits 2
// @stdout: done 4 hits 4
// @serial
// note: spawned workers pass a Sendable closure they captured to a callee: the thunk takes no rc op on the closure env, so no worker registers a root for a cell another thread owns and frees (M1).

type Dispatch = Sendable<(worker: int32, text: string) => string>;
type WorkerDispatch = Sendable<(text: string) => string>;

function onWorker(dispatch: Dispatch, worker: int32): WorkerDispatch {
	return (text: string): string => dispatch(worker, text);
}

function loop(slot: WorkerDispatch, hits: Locked<int32>): int32 {
	const reply = slot("x");
	lockedUpdate(hits, (n: int32): int32 => n + reply.length as int32);
	return 0;
}

function serve(dispatch: Dispatch, hits: Locked<int32>, workers: int32): int32 {
	const running: Promise<int32>[] = [];
	for (let worker = 2; worker <= workers; worker++) {
		const slot = onWorker(dispatch, worker);
		running.push(spawn(() => loop(slot, hits)));
	}
	const own = loop(onWorker(dispatch, 1), hits);
	const stopped = await Promise.all(running);
	return own + stopped.length as int32;
}

function stub(seen: Locked<int32>): Dispatch {
	return (worker: int32, text: string): string => {
		lockedUpdate(seen, (n: int32): int32 => n + 1);
		return `${text}${worker}`;
	};
}

function run(workers: int32): string {
	const seen: Locked<int32> = new Locked(0);
	const hits: Locked<int32> = new Locked(0);
	const dispatch = stub(seen);
	const serving = spawn(() => serve(dispatch, hits, workers));
	const done = await serving;
	return `done ${workers} hits ${lockedRead(seen, (n: int32): int32 => n)}`;
}

console.log(run(2));
console.log(run(4));
