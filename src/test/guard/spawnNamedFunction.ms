// nim-guard: spawn accepts a named function, not only an inline closure
//
// INVARIANT (PARALOCK §4, Amendment J): `spawn(fn)` and `spawn(() => fn())` are
//   the same program. The spawn lowering wraps a bare function reference into
//   the {fn, env} closure pair and, when the result needs boxing, into an
//   adapter arrow it synthesizes itself.
//
// WHAT IT CATCHES: a synthesized arrow missing a field the later passes walk.
//   Measured 2026-09-08: the adapter arrow carried no `arrowDefaults`, and the
//   lambda-lifting rename walk dereferenced it — msc died with SIGSEGV on every
//   `await spawn(namedFn)` whose result needs boxing, no diagnostic at all.
//
// RED MEANS: the compiler crashes or miscompiles the named-function spawn
//   spelling while the closure spelling still works.

function fortyOne(): int32 {
	return 41;
}

function main(): int32 {
	const a = await spawn(fortyOne);
	const f = spawn(fortyOne);
	const b = await f;
	if (a != 41) { throw "GUARD RED: fused await spawn(namedFn)"; }
	if (b != 41) { throw "GUARD RED: deferred await of spawn(namedFn)"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(main());
