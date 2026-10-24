// nim-guard: spawn of a let-bound closure is refused (P1cap)
//
// INVARIANT: spawn decides on the spawned value, not on the argument's syntax: a function value bound by 'let' may be rebound to any closure, so it is judged nowhere and is refused.
// RED MEANS: a named function value crosses unchecked again; this program then loses updates to 'n' on C.
//
// GUARD-JS
// GUARD-CHECK-FAIL 'f' is a function value that may capture mutable state, so spawn cannot run it

async function run(): Promise<int32> {
	let n: int32 = 0;
	let f = (): int32 => { for (let i = 0; i < 100000; i += 1) n += 1; return 0; };
	const a = spawn(f); // GUARD-REFUSED
	const b = spawn(f); // GUARD-REFUSED
	await a; await b;
	return n;
}
console.log(`n=${await run()}`);
