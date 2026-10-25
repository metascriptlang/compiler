// A spawn thunk does not return what the parent only lends it
//
// INVARIANT (ULTRALOCK V5): a value reached from a BORROW capture is a view that never leaves the
//   task, not as the task's result; a view cannot outlive its source (Nim `lent`, doc/destructors.md).
//
// WHAT IT CATCHES: the result escape in three shapes: the borrowed ref itself, a struct literal
//   wrapping it, and an array holding it. Each prints its own type in the refusal.
//
// RED MEANS: a thunk result carries a Readonly view out of the task again, so the awaiter holds an
//   uncounted pointer into the parent's graph.
//
// The copy-out neighbour is pinned by spawnViewResultCopyRuns.ms, which must build and run.
//
// GUARD-JS
// GUARD-CHECK-FAIL spawn thunk returns Readonly<Counter>, which reaches a value the parent only lends
// GUARD-CHECK-FAIL spawn thunk returns { v: Readonly<Counter>; }, which reaches
// GUARD-CHECK-FAIL spawn thunk returns Readonly<Counter>[], which reaches
// GUARD-CHECK-FAIL (PARALOCK E24)

class Counter { n: int32 = 0; }

async function bareRef(): Promise<int32> {
	const c = new Counter();
	const r = await spawn(() => c); // GUARD-REFUSED
	return r.n;
}

async function inStruct(): Promise<int32> {
	const c = new Counter();
	const r = await spawn(() => ({ v: c })); // GUARD-REFUSED
	return r.v.n;
}

async function inArray(): Promise<int32> {
	const c = new Counter();
	const r = await spawn(() => [c]); // GUARD-REFUSED
	return r[0].n;
}

console.log(await bareRef() + await inStruct() + await inArray());
