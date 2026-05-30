// FIXED (callHoist ternary lowering) — a fresh RC call in a ternary BRANCH leaked.
//
// `const x = c ? f(i).ok : false` evaluates the chosen branch only, so f() can't be
// hoisted eagerly. Before the fix, callHoist bailed on ternary and the fresh Result
// leaked (~277MB over 1.5M evaluations).
//
// Fix: lowerTernary lowers it to a result temp + if/else —
//   let $r = false; if (c) { const $t = f(i); $r = $t.ok; } else { $r = false; }
// so each branch's fresh value gets its own scope. Permanent regression guard.

function provide(n: number): Result<string, string> {
	return Result.ok(`payload-${n}-xxxxxxxxxxxxxxxxxxxxxxxx`);
}

function main(): void {
	let hits = 0;
	let i = 0;
	while (i < 3000000) {
		const x = (i % 2 === 0) ? provide(i).ok : false;
		if (x) { hits = hits + 1; }
		i = i + 1;
	}
	console.log(`leak-ternary-cond hits=${hits}`);
}
main();
