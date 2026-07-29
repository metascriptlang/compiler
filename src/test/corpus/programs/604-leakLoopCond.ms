// @maxrss: 40
// @stdout: leak-loop-cond i=
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED by callHoist b3a: a fresh RC call in a LOOP condition (`while (provide(i).ok)`) re-evaluates every iteration, so a preceding hoist would be wrong. Lowered to `while (true) { const $t = provide(i); if (!($t.ok)) break; BODY }` so the per-iteration Result is destroyed at each iteration's scope exit. Permanent regression guard — was 339MB leaking, now flat.

// FIXED (b3a) — a fresh RC call in a LOOP condition leaked once per iteration.
//
// `while (provide(i).ok)` re-evaluates the call every iteration, allocating a
// fresh Result whose only use is the `.ok` bool. Before b3a the Result was
// never cleaned (the condition isn't a binding the analyzer SINKs), so RSS grew
// unbounded — ~339MB over 3M iterations.
//
// callHoist (b3a) lowers it to `while (true) { const $t = provide(i); if
// (!($t.ok)) break; BODY }` so the analyzer destroys $t at each iteration's
// scope exit. Permanent regression guard — was leaking, now flat.

function provide(n: number): Result<string, string> {
	return Result.ok(`payload-${n}-xxxxxxxxxxxxxxxxxxxxxxxx`);
}

function main(): void {
	let i = 0;
	while (provide(i).ok) {
		i = i + 1;
		if (i >= 3000000) { break; }
	}
	console.log(`leak-loop-cond i=${i}`);
}
main();
