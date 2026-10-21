// nim-guard: a nested function declaration passed to spawn is judged at its declaration (P1cap)
//
// INVARIANT: the variant of spawnLetClosureRejects on the declaration kind: a local 'function f' is walked in its home scope, so its capture of a mutable is refused.
// RED MEANS: a local function declaration is taken as a module routine and crosses unchecked.
//
// GUARD-JS
// GUARD-CHECK-FAIL mutable variable 'n' cannot be captured by spawn

async function run(): Promise<int32> {
	let n: int32 = 0;
	function f(): int32 { for (let i = 0; i < 100000; i += 1) n += 1; return 0; }
	const a = spawn(f);
	const b = spawn(f);
	await a; await b;
	return n;
}
console.log(`n=${await run()}`);
