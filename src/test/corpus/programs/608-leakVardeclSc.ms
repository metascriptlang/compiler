// @maxrss: 40
// @stdout: leak-vardecl-sc hits=
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED by callHoist: a fresh RC call in a short-circuit operand of a VARDECL initializer (`const x = a && provide(i).ok`) leaked — the vardecl path used to skip conditional-eval initializers. Fix routes vardecl/assign initializers through lowerBoolCond (same flag/nested-if as if-cond). Permanent regression guard — was 277MB leaking, now flat.

// FIXED (callHoist b/vardecl short-circuit) — a fresh RC call in a short-circuit
// operand of a VARDECL initializer leaked.
//
// `const x = a && provide(i).ok` runs provide() only when `a` holds. callHoist's
// vardecl path used to skip any conditional-eval initializer, so the fresh Result
// leaked (~277MB over 1.5M evaluations). Fix routes vardecl/assign initializers
// through lowerBoolCond (same flag/nested-if as if-cond). Permanent regression guard.

function provide(n: number): Result<string, string> {
	return Result.ok(`payload-${n}-xxxxxxxxxxxxxxxxxxxxxxxx`);
}

function main(): void {
	let hits = 0;
	let i = 0;
	while (i < 3000000) {
		const a = (i % 2 === 0);
		const x = a && provide(i).ok;
		if (x) { hits = hits + 1; }
		i = i + 1;
	}
	console.log(`leak-vardecl-sc hits=${hits}`);
}
main();
