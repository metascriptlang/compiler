// A failing assert borrows its message; the location that owns the string is destroyed once
// INVARIANT: who owns an expression's value is decided by the analyzer, never by the codegen of the statement consuming it

import { execFileCapture, cwd, env, exit } from "std/process";

function fixtureVerdict(msc: string, root: string): string {
	const r = execFileCapture(msc, ["test", root + "/src/test/guard/fixtures/assertMessageBorrow.test.ms", "--cc=clang", "--sanitize=address"]);
	if (r.ok) return "the fixture's assert did not fail";
	if (r.error.signal !== 0) return "msc itself died by signal " + r.error.signal.toString();
	if (r.error.exitCode !== 1) return "msc test exited " + r.error.exitCode.toString() + "\n" + r.error.output + r.error.errorOutput;
	if (!r.error.output.contains("AssertionError: abcc")) return "the message was not reported\n" + r.error.output;
	if (r.error.errorOutput.contains("AddressSanitizer")) return "sanitizer report\n" + r.error.errorOutput;
	return "";
}

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : root + "/msc";
const why = fixtureVerdict(msc, root);
if (why != "") {
	console.log("GUARD-FAIL " + why);
	exit(1);
}
console.log("GUARD-OK");
