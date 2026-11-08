// An owned cycle that becomes garbage stops a debug build on C and Raiser, naming its class; a release build leaks it.
//
// INVARIANT: a class whose every cycle passes an Owned<T> edge stays under the collector in a debug build,
// and the collector refuses a dead set holding one before freeing it (runtime/drc.c refuseOwnedCycle,
// Raiser orcCollect); a release build classifies it acyclic, so the same cycle is never collected.
//
// WHAT IT CATCHES: the debug classification dropping the owned-cycle flag (the cycle leaks silently in
// debug too), the collector freeing the set without the report, or a release build still paying the
// collector for the class.

import { execFileCapture, cwd, env, exit } from "std/process";

function requireCondition(ok: boolean, detail: string): void {
	if (!ok) {
		console.log("GUARD-FAIL " + detail);
		exit(1);
	}
}

const WANT = "an owned cycle became garbage: N";

function checkStops(msc: string, args: string[], label: string): void {
	const r = execFileCapture(msc, args);
	requireCondition(!r.ok, label + ": an owned cycle must stop a debug build\n" + (r.ok ? r.value : ""));
	if (!r.ok) {
		const said = r.error.output + r.error.errorOutput;
		requireCondition(said.contains(WANT), label + ": no owned-cycle report\n" + said);
		requireCondition(!said.contains("made 2"), label + ": the program ran past the collection\n" + said);
	}
}

function checkReleaseLeaks(msc: string, fixture: string): void {
	const r = execFileCapture(msc, ["run", "--release", fixture]);
	requireCondition(r.ok, "release: the leaked cycle must not stop the program\n" + (r.ok ? "" : r.error.output + r.error.errorOutput));
	if (r.ok) requireCondition(r.value.contains("made 2 gone 0"), "release: the owned cycle must stay uncollected\n" + r.value);
}

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : root + "/msc";
const fixture = root + "/src/test/guard/fixtures/ownedCycle.ms";
checkStops(msc, ["run", fixture], "c");
checkStops(msc, ["run", "--target=raiser", fixture], "raiser");
checkReleaseLeaks(msc, fixture);
console.log("GUARD-OK");
