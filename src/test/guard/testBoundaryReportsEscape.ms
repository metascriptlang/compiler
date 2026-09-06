// nim-guard: the test framework is the CATCH SITE — a test body that lets an
// exception escape did not complete, and must be reported as a FAILURE.
//
// INVARIANT: a test outcome is "passed" only if the body ran to completion.
//   Reference: Nim's `assert` raises `AssertionDefect` and its own doc states
//   the other half of the contract — "This exception is only supposed to be
//   caught by unit testing frameworks" (lib/std/assertions.nim). The framework
//   catches; nothing else may swallow it, and nothing may ignore it.
// NIM-REF: §1 "Assert failure exits via raise; the framework is the catch site"
//   — DIVERGE-UNINTENTIONAL -> SAME. `ms_test_main` (runtime/core/test.h) called
//   `e->fn()` and read only `__ms_test_failed`, never `msErr`, so ANY uncaught
//   exception escaping a test body was silently reported ✓ PASS. Restored by
//   consuming the in-flight exception at the boundary per row 61's bare-catch
//   contract (`msDiscardCurrentException` = decref + null).
//
// WHY A SUBPROCESS: the observable is the RUNNER's verdict on a FAILING test,
//   which a passing test file cannot express about itself. So this guard spawns
//   the msc under test on a fixture that must fail, and asserts the exit code.
//   `cwd()` is the recompiler root when run the standard way
//   (`./msc test src/test/guard/testBoundaryReportsEscape.ms`), so `./msc` is
//   the freshly built binary being guarded — not whatever is on $PATH.
//
// RED PRE-FIX: the fixture's escaping throw is swallowed, the runner prints
//   "1 passed" and exits 0 -> the assert below fails.
// GREEN POST-FIX: the fixture is reported failed, exit code is non-zero.

import { execFile, cwd } from "std/process";

test "a test whose body throws is reported as a failure, not a pass" {
	const root = cwd();
	const mscPath = root + "/msc";
	const fixture = root + "/src/test/guard/fixtures/escapingThrow.test.ms";

	const code = execFile(mscPath, ["test", fixture]);
	assert code == 1, "an escaping exception was reported as a passing test";
}
