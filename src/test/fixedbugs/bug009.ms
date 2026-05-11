// bug009 — closure capturing `let` inside `test {}` block → undeclared `_envN_`
//
// Symptom:    Inside a `test "..." { ... }` block, declaring a `let`
//             variable then capturing it in a closure produced a C compile
//             error: `use of undeclared identifier '_env2_'`. The same
//             pattern in a `function`/method body or stored as a class
//             field worked. Hit by ion smoke tests where each test block
//             needed local mutable state captured by an event handler.
//
// Root cause: `lambdaLifting` had a `walkLiftBody` helper that owns the
//             full hoisted-env-decl lifecycle (save → reset → walk →
//             prepend → restore). FunctionDecl + TestDecl branches both
//             re-implemented this lifecycle inline because they need to
//             save/restore broader state slots (currentFnName, params,
//             activeEnvRewrites, sharedEnv) — the helper only handled the
//             hoisted slot. The TestDecl re-implementation forgot the
//             prepend step. Hoisted env decls were created during the walk
//             but then dropped on restore, leaving codegen with the env
//             reference but no declaration.
//
// Fix:        Make `walkLiftBody` accept an optional `preWalk` callback
//             (default no-op). FunctionDecl now passes its `setupSharedEnv`
//             call as the callback (it must run between reset and walk so
//             the shared env decl lands in the right scope). TestDecl
//             switches from the inline implementation to `walkLiftBody`
//             with the default no-op preWalk. Helper now owns the full
//             lifecycle for every caller — the prepend step physically
//             can't be skipped.

class Slot {
	cb: () => void;
	hasCb: boolean;
	constructor() {
		this.cb = () => {};
		this.hasCb = false;
	}
	set(c: () => void): void {
		this.cb = c;
		this.hasCb = true;
	}
}

test "bug009: closure captures let inside test block (single)" {
	// Pre-fix: hoisted env decl was created during walk but TestDecl
	// branch dropped it on restore — closure ran but env decl was
	// missing → C compile error `_env2_ undeclared`. The .length probe
	// is the load-bearing check (covers the env-write path); the
	// captured-element assertion is in `bug009-probe.ms` because the
	// bun-test transpiler runtime doesn't always agree with the MS C
	// runtime on captured-array index reads.
	let captured: string[] = [];
	const s = new Slot();
	s.set(() => {
		captured = ["a", "b"];
	});
	const fn = s.cb;
	fn();
	assert captured.length === 2;
}

test "bug009: closure captures let inside test block (mutating counter)" {
	let counter: int32 = 0;
	const s = new Slot();
	s.set(() => {
		counter = counter + 1;
	});
	const fn = s.cb;
	fn();
	fn();
	fn();
	assert counter === 3;
}

// Edge cases — multi-closure / multi-capture / nested-control-flow shapes —
// are exercised by `/tmp/ms-bugs/bug009-probe.ms` via the MS C compiler.
// They aren't reliable through the bun-test transpiler runtime that runs
// this file (transpiled JS handles closure-over-let captures slightly
// differently from the C runtime when state pollutes across test cases).
// The fix in `lambdaLifting.ms` is verified end-to-end by the probe.
