// A ref argument inside a decomposed assert is the caller's own value, so the call's writes stay visible after the assert
// INVARIANT: a call writes through a ref parameter to the caller's location on every backend, inside an assert included

import { execFileCapture, cwd, env, exit } from "std/process";

function fixtureVerdict(msc: string, root: string, target: string): string {
	const r = execFileCapture(msc, ["test", "--target=" + target, root + "/src/test/guard/fixtures/assertRefArgument.test.ms"]);
	if (r.ok) return "";
	return "msc test exited " + r.error.exitCode.toString() + "\n" + r.error.output + r.error.errorOutput;
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
