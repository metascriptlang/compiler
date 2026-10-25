// A spawn thunk may return a scalar read out of what it borrows, and the parent closes over that
//
// INVARIANT (ULTRALOCK V5, V1): a scalar read out of a view is a COPY that leaves the task; a closure
//   built after the await captures the parent's own copy. Only a closure over the borrowed capture
//   itself is held back (spawnClosureResultRejects.ms).
//
// RED MEANS: the closure-escape refusal also catches a scalar result, or a closure the parent builds
//   from it after the task ended.
//
// GUARD-JS

class Counter { n: int32 = 0; }

async function main(): Promise<void> {
	const c = new Counter();
	c.n = 4;
	const n = await spawn(() => c.n);
	const f = () => n;
	c.n = 5;
	if (f() != 4) throw new Error(`scalar copy: f=${f()}`);
	console.log("GUARD-OK");
}

await main();
