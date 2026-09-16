// A failing assert borrows its message; the location that owns the string is destroyed once
// INVARIANT: who owns an expression's value is decided by the analyzer, never by the codegen of the statement consuming it
// Run as `./msc test src/test/guard/assertMessageBorrow.ms` from the recompiler root.

import { execFileCapture, cwd } from "std/process";

function fixtureVerdict(gc: string): string {
	const root = cwd();
	const r = execFileCapture(root + "/msc", ["test", root + "/src/test/guard/fixtures/assertMessageBorrow.test.ms", "--gc=" + gc, "--cc=clang", "--sanitize=address"]);
	if (r.ok) return "the fixture's assert did not fail";
	if (r.error.signal !== 0) return "msc itself died by signal " + r.error.signal.toString();
	if (r.error.exitCode !== 1) return "msc test exited " + r.error.exitCode.toString() + "\n" + r.error.output + r.error.errorOutput;
	if (!r.error.output.contains("AssertionError: abcc")) return "the message was not reported\n" + r.error.output;
	if (r.error.errorOutput.contains("AddressSanitizer")) return "sanitizer report\n" + r.error.errorOutput;
	return "";
}

test "drc: the failing assert reports its borrowed message once" {
	const why = fixtureVerdict("drc");
	assert why === "", "drc: " + why;
}

test "orc: the failing assert reports its borrowed message once" {
	const why = fixtureVerdict("orc");
	assert why === "", "orc: " + why;
}
