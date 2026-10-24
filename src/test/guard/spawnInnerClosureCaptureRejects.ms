// nim-guard: a closure created inside a spawn thunk shares the thunk's captures (P1cap)
//
// INVARIANT: the variant of spawnLetClosureRejects one nesting level deeper: the capture walk descends into a nested closure, whose own parameters bind.
// RED MEANS: the walk stops at a nested routine, and its write to the parent's 'n' races.
//
// GUARD-JS
// GUARD-CHECK-FAIL mutable variable 'n' cannot be captured by spawn

async function run(): Promise<int32> {
	let n: int32 = 0;
	const a = spawn((): int32 => { const g = (): void => { for (let i = 0; i < 100000; i += 1) n += 1; }; g(); return 0; }); // GUARD-REFUSED
	const b = spawn((): int32 => { const g = (): void => { for (let i = 0; i < 100000; i += 1) n += 1; }; g(); return 0; }); // GUARD-REFUSED
	await a; await b;
	return n;
}
console.log(`n=${await run()}`);
