// @xfail(raiser): raiser runtime error: Unknown host function: msSleepAsync
// @skip-js: spawn has no working js lowering - the emitted
//   _std/core/promise/index.js dies at "TypeError: Promise.resolve is not a
//   function" before any user code runs (measured 2026-09-07, tree mode, after
//   this file moved off waitFor onto await). Same class as 405/406/414/415.
// @stdout: spawn-timer done 100
// @serial

// note: A timer armed from inside a spawn task must fire. The timer heap hangs
//   off the THREAD-LOCAL dispatcher (`gDispatcher`, dispatchFull.c), while a
//   pool worker never runs an event loop - it only helps or parks on the
//   completion condvar (msWaitFor's worker arm). So a worker that calls
//   msSleepAsync mints a dispatcher of its own, pushes the timer onto a heap
//   no thread ever polls, and the awaiting future never completes: the program
//   hangs forever rather than failing.
//   PROVEN RED 2026-09-05 (Windows, drc, mscW36): this program hung 6 of 6 runs
//   at a 20s cap, printing nothing. The one-handle probe it grew out of hung
//   only 5 of 6 - that escapee is the race this shape removes: with a single
//   spawn in flight the main thread can win msPoolHelpOne and run the thunk
//   itself, landing the timer on the real loop's heap and passing for the wrong
//   reason. Four handles in flight per round leave at most one for the helper,
//   so at least three go to real workers every round.
//   Sibling coverage before this program: 722/723 are the ONLY other corpus
//   users of sleepAsync and both call it from top-level main, i.e. always on
//   the loop thread - the worker-side path had zero coverage in any tier.
//   Same family as the 419 hang (a pool worker minting a completion channel
//   nobody drains); this is the timer half of it.
//   The js/esm lanes are skipped, not xfailed: the shape this program needs
//   (a blocking await INSIDE a spawn thunk, so the timer is armed on a pool
//   worker) has no working js lowering at all - there is nothing for those
//   lanes to run.
//   NOT verified on this host: macOS/kqueue, where the same thread-local
//   dispatcher and heap are shared code but were never measured. Linux WAS
//   measured (WSL, cross-built drc): 6/6 hang before the fix, 6/6 pass after.
async function tick(): Promise<int32> {
	await sleepAsync(1);
	return 1;
}

function main(): void {
	let total = 0;
	for (let round = 0; round < 25; round = round + 1) {
		const a = spawn(() => { return await tick(); });
		const b = spawn(() => { return await tick(); });
		const c = spawn(() => { return await tick(); });
		const d = spawn(() => { return await tick(); });
		total = total + (await a) + (await b) + (await c) + (await d);
	}
	console.log(`spawn-timer done ${total}`);
}

main();
