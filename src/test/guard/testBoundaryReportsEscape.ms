// nim-guard: the test framework is the CATCH SITE — a test body that lets an
// exception escape did not complete, and must be reported as a FAILURE.
//
// INVARIANT: a test outcome is "passed" only if the body ran to completion.
//   Reference: Nim's `assert` raises `AssertionDefect` and its own doc states
//   the other half of the contract — "This exception is only supposed to be
//   caught by unit testing frameworks" (lib/std/assertions.nim). The framework
//   catches; nothing else may swallow it, and nothing may ignore it.
// NIM-REF TR-15
//   — DIVERGE-UNINTENTIONAL -> SAME. `ms_test_main` (runtime/core/test.h) called
//   `e->fn()` and read only `__ms_test_failed`, never `msErr`, so ANY uncaught
//   exception escaping a test body was silently reported ✓ PASS. Restored by
//   consuming the in-flight exception at the boundary per row 61's bare-catch
//   contract (`msDiscardCurrentException` = decref + null).
//
// WHY A SUBPROCESS: the observable is the RUNNER's verdict on a FAILING test,
//   which a passing test file cannot express about itself. So this guard spawns
//   the msc under test on a fixture that must fail, and checks the exit code.
//
// RED PRE-FIX: the fixture's escaping throw is swallowed, the runner prints
//   "1 passed" and exits 0 -> the consumer check below fails.
// GREEN POST-FIX: the fixture is reported failed, exit code is non-zero.

import { execFile, execFileCapture, cwd, env, exit } from "std/process";

function requireCondition(ok: boolean, detail: string): void {
	if (!ok) {
		console.log("GUARD-FAIL " + detail);
		exit(1);
	}
}

function checkEscapingThrow(mscPath: string, root: string): void {
	const fixture = root + "/src/test/guard/fixtures/escapingThrow.test.ms";

	const code = execFile(mscPath, ["test", fixture, "--tests-in-dir"]);
	requireCondition(code == 1, "an escaping exception was reported as a passing test");
}

function checkAssertionMessages(mscPath: string, root: string): void {
	const fixture = root + "/src/test/guard/fixtures/macroAssertionMessageDependencies.test.ms";
	for (const target of ["c", "js"]) {
		const result = execFileCapture(mscPath, ["test", fixture, "--tests-in-dir", "--target=" + target]);
		requireCondition(!result.ok, target + " must report the deliberate assertion failures");
		if (!result.ok) {
			const output = result.error.output + result.error.errorOutput;
			requireCondition(result.error.exitCode == 1, target + "\n" + output);
			requireCondition(output.contains("constant-message-payload"), target + "\n" + output);
			requireCondition(output.contains("helper-message-payload"), target + "\n" + output);
			requireCondition(output.contains("enum-message-Second"), target + "\n" + output);
			requireCondition(output.contains("3 failed"), target + "\n" + output);
			requireCondition(output.contains("macroAssertionMessageDependencies.test.ms (4)"), target + " did not execute the passing-path control\n" + output);
		}
	}
}

const root = cwd();
const mscEnv = env.get("MSC");
const mscPath = mscEnv != "" ? mscEnv : root + "/msc";
checkEscapingThrow(mscPath, root);
checkAssertionMessages(mscPath, root);
console.log("GUARD-OK");
