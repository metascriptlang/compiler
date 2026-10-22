// A spawn thunk does not return a closure over what the parent only lends it
//
// INVARIANT (ULTRALOCK V5, V0): a BORROW capture never leaves the task, not as the task's result;
//   a closure carries its env, so the escape is judged by what the returned closure captures, at
//   any nesting depth and inside a literal that wraps it, never by the closure's type.
//
// WHAT IT CATCHES: a returned closure that reads a borrowed capture, one nested two levels deep,
//   and one returned inside an object literal. Each captures its own name, which the refusal prints.
//
// RED MEANS: the awaiter can call a closure whose env still points into the parent's lent storage
//   after the task ended.
//
// The scalar neighbour is pinned by spawnClosureResultCopyRuns.ms, which must build and run.
//
// GUARD-JS
// GUARD-CHECK-FAIL spawn thunk returns a closure that captures 'a', which the parent only lends
// GUARD-CHECK-FAIL spawn thunk returns a closure that captures 'b'
// GUARD-CHECK-FAIL spawn thunk returns a closure that captures 'k'
// GUARD-CHECK-FAIL (PARALOCK E24)

class Counter { n: int32 = 4; }

async function oneLevel(): Promise<int32> {
	const a = new Counter();
	const f = await spawn(() => () => a.n);
	return f();
}

async function twoLevels(): Promise<int32> {
	const b = new Counter();
	const f = await spawn(() => () => () => b.n);
	return f()();
}

async function inObject(): Promise<int32> {
	const k = new Counter();
	const r = await spawn(() => ({ f: () => k.n }));
	return r.f();
}

console.log(await oneLevel() + await twoLevels() + await inObject());
