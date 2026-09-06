// nim-guard: a failing `assert` must leave the enclosing function through the
// RAISE path, never a bare `return;`.
//
// INVARIANT: the assert failure exit must be valid regardless of the enclosing
//   function's C return type, at any lambda nesting depth. Reference: Nim's
//   `assert` expands to `failedAssertImpl` -> `raiseAssert` (`{.noreturn.}`,
//   lib/std/assertions.nim) — it RAISES. A raise is return-type agnostic, so
//   Nim's assert works identically inside a lambda returning any type, and the
//   unwind reaches the test framework ("this exception is only supposed to be
//   caught by unit testing frameworks" — assert's own doc comment).
// NIM-REF: §1 "Assert failure exits via raise, framework is the catch site" —
//   DIVERGE-UNINTENTIONAL -> SAME. `genAssertStmt` emitted
//   `msTestCheckFail(...); return;`, which (a) is ILL-FORMED C in a non-void
//   function and (b) even where it compiles only returns from the innermost
//   lambda, not the test. Restored via `msErr = MS_TRUE` + emitPendingErrorGoto
//   (the same error target genThrowStmt uses), with the test boundary
//   (ms_test_main) consuming the in-flight exception per row 61.
//
// RED PRE-FIX: cases 1 and 4 fail to COMPILE —
//   "non-void function 'dollarfn_...' should return a value [-Wreturn-mismatch]"
//   so the whole guard file is red. Cases 2/3 are the no-regression shapes that
//   compiled before and must keep passing.

function runGeneric<T>(fn: (d: () => void) => T): T {
	const d = (): void => {};
	return fn(d);
}

test "1: assert inside a concretely-typed non-void arrow" {
	const double = (v: number): number => {
		assert v > 0, "positive";
		return v * 2;
	};
	assert double(3) == 6, "doubled";
}

test "2: assert inside a void arrow still works" {
	let seen = 0;
	const bump = (v: number): void => {
		assert v > 0, "positive";
		seen = (seen + v) as int32;
	};
	bump(3);
	assert seen == 3, "ran";
}

test "3: assert directly in the test body still works" {
	const x = 1 + 1;
	assert x == 2, "x is 2";
}

test "4: assert inside a generic callback whose type param is unresolved" {
	runGeneric((d) => {
		const x = 1 + 1;
		assert x == 2, "x is 2";
		d();
	});
}

test "5: assert inside an arrow returning a string" {
	const label = (v: number): string => {
		assert v >= 0, "non-negative";
		return v.toString();
	};
	assert label(7) == "7", "stringified";
}

test "6: assert nested two arrows deep in a non-void chain" {
	const outer = (v: number): number => {
		const inner = (w: number): number => {
			assert w > 0, "inner positive";
			return w + 1;
		};
		assert v > 0, "outer positive";
		return inner(v) * 2;
	};
	assert outer(2) == 6, "nested";
}
