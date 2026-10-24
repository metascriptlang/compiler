// nim-guard: a timed spawn passed to a call, to a Promise.all that is not awaited, or to an awaited Promise.all of mixed elements is refused.
//
// INVARIANT (ULTRALOCK T2): a timed spawn's deadline is taken at the await that is
//   written around it, so a timed spawn is accepted only as the operand of that
//   await; a handle that travels anywhere else would carry no deadline.
//
// WHAT IT CATCHES: a timed handle handed to a combinator or a callee, which awaits it with no deadline.
//
// RED MEANS: a timed spawn passed as an argument compiled.
//
// GUARD-CHECK-FAIL a spawn with { timeout } must be awaited where it is written
// GUARD-CHECK-FAIL needs every element of the array to be a spawn

function first(p: Promise<int32>): int32 {
	return await p;
}

function run(): int32 {
	const all = Promise.all([spawn((): int32 => 1, { timeout: 10 }), spawn((): int32 => 2)]); // GUARD-REFUSED
	const rs = await all;
	const mixed = await Promise.all([spawn((): int32 => 4, { timeout: 10 }), first(spawn((): int32 => 5))]); // GUARD-REFUSED
	return rs[0] + rs[1] + mixed[0] + first(spawn((): int32 => 3, { timeout: 10 })); // GUARD-REFUSED
}

console.log(`${run()}`);
