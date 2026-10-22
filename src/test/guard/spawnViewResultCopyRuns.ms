// A spawn thunk may return a scalar or a string read out of what it borrows
//
// INVARIANT (ULTRALOCK V5, V1): a scalar or a string read out of a view is a COPY and may leave the
//   task as its result; only the view itself is held back (spawnViewResultRejects.ms).
//
// RED MEANS: the result-escape refusal also catches a copy, so a plain read of a borrowed field
//   no longer compiles.
//
// GUARD-JS

class Counter { n: int32 = 0; label: string = ""; }

async function main(): Promise<void> {
	const c = new Counter();
	c.n = 7;
	c.label = "seven";
	const n = await spawn(() => c.n);
	const s = await spawn(() => c.label);
	const both = await spawn(() => ({ n: c.n, s: c.label }));
	if (n != 7 || s != "seven" || both.n != 7 || both.s != "seven") throw new Error(`copy-out: n=${n} s=${s}`);
	c.n = 8;
	if (n != 7) throw new Error("the copied scalar followed the source");
	console.log("GUARD-OK");
}

await main();
