// @stdout: number=7 threads=1 poolThreads=0 quiet=true
// @stdout: string=seven threads=1 poolThreads=0 quiet=true
// @stdout: spawned=6 poolStarted=true
// @serial
// @skip-js: binds the C fixture loopWakes.c and reads the C runtime worker pool
// @skip-raiser: binds the C fixture loopWakes.c; the Raiser runs spawn inline and has no worker pool
// note: a blocking top-level await of a timer polls this thread's loop until the timer fires: the process keeps its one OS thread and the wait sleeps in the poller until the timer is due, a handful of context switches for 250 ms (old runtime: the wait's help step started the pool, one thread per CPU, and woke every 5 ms, about 50 switches). The number await takes the typed wait and the string await the untyped one; the first spawn still starts the pool and its await settles.

@include("./loopWakes.h")
@compile("./loopWakes.c")
extern function msTestOsThreads(): int32;
extern function msTestContextSwitches(): int32;
extern function msPoolThreadPeek(): int32;

function later<T>(ms: number, value: T): Promise<T> {
	return new Promise<T>((resolve) => {
		setTimeout(() => { resolve(value); }, ms);
	});
}

const quietSwitches = 15;

let before = msTestContextSwitches();
const n = await later(250, 7);
let switches = msTestContextSwitches() - before;
console.log(`number=${n} threads=${msTestOsThreads()} poolThreads=${msPoolThreadPeek()} quiet=${switches < quietSwitches}`);

before = msTestContextSwitches();
const s = await later(250, "seven");
switches = msTestContextSwitches() - before;
console.log(`string=${s} threads=${msTestOsThreads()} poolThreads=${msPoolThreadPeek()} quiet=${switches < quietSwitches}`);

const w = await spawn((): int32 => 6);
console.log(`spawned=${w} poolStarted=${msPoolThreadPeek() > 0}`);
