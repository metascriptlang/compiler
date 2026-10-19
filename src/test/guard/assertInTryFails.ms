// A failing assert inside `try` fails its test on every backend; no `catch` in the test body sees it
// INVARIANT (NIM-REF RT-34): a failed run-time check, an assert included, is a defect no emitted catch handles

import { execFileCapture, cwd, env, exit } from "std/process";

function fixtureVerdict(msc: string, root: string, target: string): string {
	const r = execFileCapture(msc, ["test", "--target=" + target, root + "/src/test/guard/fixtures/assertInTry.test.ms"]);
	if (r.ok) return "the fixture's assert was caught inside the test";
	if (r.error.exitCode !== 1) return "msc test exited " + r.error.exitCode.toString() + "\n" + r.error.output + r.error.errorOutput;
	if (!r.error.output.contains("AssertionError: boom")) return "the assert message was not reported\n" + r.error.output;
	return "";
}

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : root + "/msc";
for (const target of ["js", "c"]) {
	const why = fixtureVerdict(msc, root, target);
	if (why != "") {
		console.log("GUARD-FAIL " + target + ": " + why);
		exit(1);
	}
}
console.log("GUARD-OK");
