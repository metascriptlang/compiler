// A failing assert inside `try` fails its test on every backend; no `catch` in the test body sees it
// INVARIANT (NIM-REF RT-34): a failed run-time check, an assert included, is a defect no emitted catch handles
// Run as `./msc test src/test/guard/assertInTryFails.ms` from the recompiler root.

import { execFileCapture, cwd } from "std/process";

function fixtureVerdict(target: string): string {
	const root = cwd();
	const r = execFileCapture(root + "/msc", ["test", "--target=" + target, root + "/src/test/guard/fixtures/assertInTry.test.ms"]);
	if (r.ok) return "the fixture's assert was caught inside the test";
	if (r.error.exitCode !== 1) return "msc test exited " + r.error.exitCode.toString() + "\n" + r.error.output + r.error.errorOutput;
	if (!r.error.output.contains("AssertionError: boom")) return "the assert message was not reported\n" + r.error.output;
	return "";
}

test "js: a failing assert inside try fails the test" {
	const why = fixtureVerdict("js");
	assert why === "", "js: " + why;
}

test "c: a failing assert inside try fails the test" {
	const why = fixtureVerdict("c");
	assert why === "", "c: " + why;
}
