// @skip-js: waitFor() is a C-backend intrinsic (see 421-spawnSleepTimer); the
//   { timeout } options object rides the same fused C-only lowering, so there
//   is no js spelling of this shape at all.
// @stdout: spawn-timeout done 100
// @serial

// note: A timed spawn wait must SURVIVE a task that only the event loop can
//   complete. Two defects made this path hang before 2026-09-05:
//   1. msAwaitGroupBlockingWithDeadline parked the LOOP thread on the group
//      condvar without ever pumping the event loop - the timer half of the
//      421 family. A spawn child blocked on sleepAsync arms a timer only a
//      loop thread can service, and the only loop thread was parked, so the
//      child never finished and the wait never returned.
//   2. The timeout emission called msAwaitGroupFree while children were
//      still in flight. msAwaitGroupFree spins on finishDone, which only the
//      last child's finishSlot sets - so a timeout that fires while a child
//      is blocked hangs FOREVER, silently, past its own deadline. The
//      runtime's own contract (awaitGroup.h: "Safe to call only after all
//      slots have completed - calling during an outstanding submission is
//      UB") had been violated by the transform since Phase 3.
//   PROVEN RED 2026-09-05 (Windows, drc, mscW37, pre-fix runtime): 4 ok /
//   2 hang over 6 runs at a 30s cap - silent, no output, burning a core.
//   Flaky because the run only hangs when a real pool worker steals the
//   child before the main thread's msPoolHelpOne can run it inline (the
//   inline-run case services its own timer).
//   The deadline rounds are deliberately NOT pinned: a deadline that fires
//   while the waiter itself is help-running the child inline cannot throw -
//   help executes the whole thunk as one uninterruptible step, and the child
//   blocked on a timer is exactly what the helper's own pumping completes.
//   Measured 2026-09-05: a 300ms task under a 60ms deadline returned its
//   value (v=9) whenever help won the race, threw correctly when a worker
//   stole the child. Deadline granularity is therefore cooperative yield
//   points, the same class of limit as the standard reference's
//   non-preemptive event loop callbacks - a strict-deadline change would be
//   a model amendment, not a bug fix.
async function tick(): Promise<int32> {
	await sleepAsync(1);
	return 1;
}

function main(): void {
	let total = 0;
	for (let round = 0; round < 25; round = round + 1) {
		// Fused form - `const h = spawn(fn, {timeout}); await h` (deferred)
		// does not parse the options object and fails at the C boundary
		// (msSpawn takes one argument), so this IS the only live spelling.
		total = total + (await spawn(() => waitFor(tick()), { timeout: 4000 }));
		total = total + (await spawn(() => waitFor(tick()), { timeout: 4000 }));
		total = total + (await spawn(() => waitFor(tick()), { timeout: 4000 }));
		total = total + (await spawn(() => waitFor(tick()), { timeout: 4000 }));
	}
	console.log(`spawn-timeout done ${total}`);
}

main();
