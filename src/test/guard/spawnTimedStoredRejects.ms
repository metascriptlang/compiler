// nim-guard: a timed spawn stored in a binding is refused.
//
// INVARIANT (ULTRALOCK T2): a timed spawn's deadline is taken at the await that is
//   written around it, so a timed spawn is accepted only as the operand of that
//   await; a handle that travels anywhere else would carry no deadline.
//
// WHAT IT CATCHES: the stored timed handle compiling again; it reached C as msSpawn with two arguments and clang refused the call.
//
// RED MEANS: the stored timed spawn compiled.
//
// GUARD-CHECK-FAIL a spawn with { timeout } must be awaited where it is written

function run(): int32 {
	const h = spawn((): int32 => 1, { timeout: 10 }); // GUARD-REFUSED
	return await h;
}

async function runAsync(): Promise<int32> {
	const h = spawn((): int32 => 2, { timeout: 10 }); // GUARD-REFUSED
	return await h;
}

console.log(`${run()}`);
console.log(`${await runAsync()}`);
