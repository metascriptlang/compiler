// nim-guard: untyped arrow params are contextually typed THROUGH a Maybe (`fn | null`) formal
//
// INVARIANT: an arrow with untyped params passed to a parameter of type
//   `fn | null` takes the inner function's param types — identical to a bare
//   `fn` formal. (checkAnonymousFunction: contextual param/return typing)
// NIM-REF: §1 "Contextual param typing peels Maybe" — DIVERGE-INCOMPLETE -> SAME.
//   Both the contextual-param gate and the contextual-return-fallback gate only
//   accepted TypeKind.Function. A `fn|null` formal is a Maybe struct (IsMaybe),
//   not Function, so untyped params fell to unknown -> void*. Fix peels the Maybe
//   via typeReturn before both gates, restoring parity with the bare-fn path.
//
// WHAT IT CATCHES: arrow params erased to void* whenever the callback formal is
//   nullable. Only surfaces as a C error when the body forces the concrete type
//   (comparing a param to a double literal) — `a === b` alone stays void*==void*
//   and compiles wrongly-typed. RED = build failure ("void *" and "double") or a
//   wrong runtime value. Proven RED on the pre-fix binary; GREEN post-fix.
//
// No RC balance directive — the signal is build-failure / wrong-value-throw.

function pickNG(f: ((a: number, b: number) => boolean) | null): boolean {
	if (f !== null) { return f(1.0, 2.0); }
	return false;
}

function pickG<T>(x: T, f: ((a: T, b: T) => boolean) | null): boolean {
	if (f !== null) { return f(x, x); }
	return false;
}

function main(): void {
	const ng = pickNG((a, b) => (a !== 0.0) === (b !== 0.0));
	const g = pickG(3.5, (a, b) => (a !== 0.0) === (b !== 0.0));
	if (!ng) { throw "GUARD RED: non-generic Maybe-fn arrow param not contextually typed"; }
	if (!g) { throw "GUARD RED: generic Maybe-fn arrow param not contextually typed"; }
	console.log("maybeArrowParamContext ok");
}
