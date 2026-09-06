// bug095 — expression-bodied arrow whose nested arrow captures an outer
// binding: hard C error `use of undeclared identifier '_env_…'`.
//
// Symptom:    `() => call(() => x + 1)` failed to compile on C — the inner
//             closure referenced the outer arrow's env struct, but that env
//             was never declared or initialized in the emitted C. The
//             block-bodied spelling `() => { return call(() => x + 1); }`
//             compiled fine.
// Root cause: `walkLiftBody` can only prepend hoisted env decls into a
//             BlockStmt body; `normalizeArrowBodies` only wrapped bodies that
//             were THEMSELVES an arrow (curried case, bug039), so an arrow
//             nested inside any other expression left the outer arrow
//             expression-bodied and `setupSharedEnv`'s hoisted `_env_…` decl
//             was silently dropped.
// Fix:        `normalizeArrowBodies` wraps EVERY non-block arrow body in
//             `{ return expr; }`, making liftCapturingClosureBody's
//             documented "body is guaranteed BlockStmt" invariant true.

function bug095Call<T>(fn: () => T): T { return fn(); }

test "bug095: expr-bodied arrow, inner captures enclosing const" {
	const x = 5;
	const producer = () => bug095Call(() => x + 1);
	assert producer() == 6, "const capture";
}

test "bug095: expr-bodied arrow, inner captures the outer arrow's param" {
	const apply = (v: number): number => bug095Call(() => v + 1);
	assert apply(5) == 6, "param capture";
}

test "bug095: inner arrow mutates the captured binding across calls" {
	let bug095n = 0;
	const bump = () => bug095Call(() => { bug095n = bug095n + 1; return bug095n; });
	assert bump() == 1, "first bump";
	assert bump() == 2, "second bump";
}

test "bug095: two nested expr-bodied arrows, innermost captures outermost const" {
	const x = 10;
	const outer = () => bug095Call(() => bug095Call(() => x + 1));
	assert outer() == 11, "double nesting";
}

test "bug095: no-capture control" {
	const producer = () => bug095Call(() => 6);
	assert producer() == 6, "control";
}
