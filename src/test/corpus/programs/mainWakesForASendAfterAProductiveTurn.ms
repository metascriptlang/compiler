// @stdout: the host wait woke for the worker's send
// @stdout: bumps 3 r 1
// @exit: 0
// @serial
// @skip-js: msAdjustTimeout and the dispatcher's selector fd are the C event loop
// @skip-raiser
// @skip-windows: an embedding host on Windows waits on the IOCP port, not on a selector fd
// note: an embedding host (Ion) asks msAdjustTimeout how long it may sleep, then waits on the dispatcher's selector fd itself. Main's last turn ran actor work, which leaves the amortized wake token set; a worker then sends to a main-homed actor. Asking for the delay must drop the token, so the send writes the wake and the host's wait ends (old runtime: the wait slept its whole 1500 ms cap).

@include("runtime/promise/dispatch.h");
@include("poll.h");
extern function msRunOnce(timeoutMs: int32): boolean;
extern function msMonoTimeMs(): int64;
extern function msGetDispatcher(): Ptr<void>;
extern function msAdjustTimeout(d: Ptr<void>, pollTimeout: int32, nextTimerMs: int32): int32;
extern function msNextTimerDelayMs(): int32;
extern function msGetDispatcherSelectorFd(): int32;
extern function poll(fds: Ptr<void>, n: uint64, timeoutMs: int32): int32;

actor Echo {
	n: int32 = 0;
	bump(): void { this.n += 1; }
	count(): int32 { return this.n; }
}

function sender(e: Readonly<Echo>): number {
	const until = performance.now() + 200;
	while (performance.now() < until) {}
	e.bump();
	const later = performance.now() + 2500;
	while (performance.now() < later) {}
	return 1;
}

function hostWait(capMs: int32): int64 {
	const delay = msAdjustTimeout(msGetDispatcher(), -1 as int32, msNextTimerDelayMs());
	const wait = delay < 0 || delay > capMs ? capMs : delay;
	let pfd: int32[2] = [msGetDispatcherSelectorFd(), 1];
	const t0 = msMonoTimeMs();
	poll(pfd as Ptr<void>, 1 as uint64, wait);
	return msMonoTimeMs() - t0;
}

function run(): void {
	const e = new Echo();
	e.bump();
	msRunOnce(0 as int32);
	e.bump();
	msRunOnce(0 as int32);
	const h = spawn((): number => sender(e));
	const waited = hostWait(1500 as int32);
	console.log(waited < 1000 ? "the host wait woke for the worker's send" : `the host wait LOST the worker's send: slept ${waited} ms`);
	const r = await h;
	console.log(`bumps ${await e.count()} r ${r}`);
}
run();
