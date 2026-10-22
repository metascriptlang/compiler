// nim-guard: a timed spawn pushed into an array is refused.
//
// INVARIANT (ULTRALOCK T2): a timed spawn's deadline is taken at the await that is
//   written around it, so a timed spawn is accepted only as the operand of that
//   await; a handle that travels anywhere else would carry no deadline.
//
// WHAT IT CATCHES: a timed handle kept in an array; the exit join would wait on it with no deadline.
//
// RED MEANS: the timed spawn in an array compiled.
//
// GUARD-CHECK-FAIL a spawn with { timeout } must be awaited where it is written

function run(): int32 {
	const hs: Promise<int32>[] = [];
	for (let k = 0; k < 2; k += 1) hs.push(spawn((): int32 => 1, { timeout: 10 }));
	let t: int32 = 0;
	for (const h of hs) t = t + await h;
	return t;
}

console.log(`${run()}`);
