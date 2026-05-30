// FIXED (b3b) — a fresh RC call in a SHORT-CIRCUIT operand leaked per evaluation.
//
// In `if (a && provide(i).ok)` the call runs only when `a` holds, so it can't be
// hoisted to a preceding statement (that would evaluate it eagerly and break the
// guard). Before b3b the fresh Result was never cleaned → RSS grew unbounded
// (~339MB over 1.5M evaluations).
//
// callHoist (b3b) lowers the short-circuit to a flag + nested-if (what Nim does
// for `and`/`or`), so the fresh call is captured into a temp only on the branch
// that reaches it and destroyed at that block's scope exit:
//   if (a && provide(i).ok) { ... }
//     →  let $f = false; if (a) { const $t = provide(i); $f = $t.ok; } if ($f) { ... }
// Permanent regression guard — was leaking, now flat.

function provide(n: number): Result<string, string> {
	return Result.ok(`payload-${n}-xxxxxxxxxxxxxxxxxxxxxxxx`);
}

function main(): void {
	let hits = 0;
	let i = 0;
	while (i < 3000000) {
		const a = (i % 2 === 0);
		if (a && provide(i).ok) { hits = hits + 1; }
		i = i + 1;
	}
	console.log(`leak-short-circuit hits=${hits}`);
}
main();
