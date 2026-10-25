// nim-guard: the actor hooks reach pool workers that already run
//
// INVARIANT: a value a running thread reads is published before it reads it:
//   a spawn starts the pool, then the first actor registers the poll and scheduler hooks that
//   every idle worker checks between tasks.
//
// WHAT IT CATCHES: a hook stored or loaded as a plain pointer; TSan reports the race between
//   the registration and a worker's poll.
//
// RED MEANS: the actor hooks lost their atomic publication.
//
// GUARD-TSAN

actor Sink {
	total: int32 = 0;
	add(n: int32): int32 { this.total = this.total + n; return this.total; }
}

function work(k: int32): int32 { return k + 1; }

async function main(): Promise<void> {
	const warm = await Promise.all([spawn(() => work(1)), spawn(() => work(2))]);
	const s = new Sink();
	let last: int32 = 0;
	for (let i: int32 = 0; i < 100; i += 1) last = await s.add(1);
	if (warm[0] + warm[1] != 5 || last != 100) { throw `GUARD RED: warm=${warm[0] + warm[1]} last=${last}`; }
	console.log("GUARD-OK");
}

main();
