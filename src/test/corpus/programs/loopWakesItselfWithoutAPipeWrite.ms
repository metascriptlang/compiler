// @stdout: own wake bytes 0
// @stdout: next sleep 0 ms
// @stdout: bumps 1
// @exit: 0
// @serial
// @skip-js: the wake pipe and msAdjustTimeout are the C event loop
// @skip-raiser
// @skip-windows: the loop on Windows wakes through its IOCP port, not a wake pipe
// note: main sends to an actor homed on its own scheduler. The loop thread is running, so the send writes nothing to its wake pipe (old runtime: one byte per send and per reply, 39,999 writes over 20k CALLs); the loop's next ready-work check still answers 0 ms, as the byte made its next poll return at once.

@include("runtime/promise/dispatch.h");
@include("poll.h");
extern function msRunOnce(timeoutMs: int32): boolean;
extern function msGetDispatcher(): Ptr<void>;
extern function msAdjustTimeout(d: Ptr<void>, pollTimeout: int32, nextTimerMs: int32): int32;
extern function msGetWakePipeFd(): int32;
extern function poll(fds: Ptr<void>, n: uint64, timeoutMs: int32): int32;

actor Echo {
	n: int32 = 0;
	bump(): void { this.n += 1; }
	count(): int32 { return this.n; }
}

function wakeBytesPending(): int32 {
	let pfd: int32[2] = [msGetWakePipeFd(), 1];
	return poll(pfd as Ptr<void>, 1 as uint64, 0 as int32);
}

function run(): void {
	const e = new Echo();
	msRunOnce(0 as int32);
	msRunOnce(0 as int32);
	e.bump();
	console.log(`own wake bytes ${wakeBytesPending()}`);
	console.log(`next sleep ${msAdjustTimeout(msGetDispatcher(), 1500 as int32, -1 as int32)} ms`);
	console.log(`bumps ${await e.count()}`);
}
run();
