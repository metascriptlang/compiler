// The test runner names the signal that killed a test binary instead of exiting 255 in silence

import { execFileCapture, cwd, env, exit, platform } from "std/process";

function requireCondition(ok: boolean, detail: string): void {
	if (!ok) {
		console.log("GUARD-FAIL " + detail);
		exit(1);
	}
}

function checkAbortIsReported(msc: string, root: string): void {
	const r = execFileCapture(msc, ["test", root + "/src/test/guard/fixtures/abortingTest.test.ms"]);
	requireCondition(!r.ok, "a killed test binary must not read as a pass");
	if (!r.ok) {
		requireCondition(r.error.exitCode == 134, "msc test exited " + r.error.exitCode.toString() + "\n" + r.error.output + r.error.errorOutput);
		requireCondition(r.error.errorOutput.contains("terminated by signal 6"), "no signal report\n" + r.error.output + r.error.errorOutput);
	}
}

function checkStackOverflowIsReported(msc: string, root: string): void {
	const r = execFileCapture(msc, ["test", root + "/src/test/guard/fixtures/stackOverflowTest.test.ms"]);
	requireCondition(!r.ok, "a crashed test binary must not read as a pass");
	if (!r.ok) {
		const want = platform == "windows" ? "terminated with status 0xC00000FD" : "terminated by signal 11";
		requireCondition(r.error.errorOutput.contains(want), "no crash report\n" + r.error.output + r.error.errorOutput);
	}
}

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : root + "/msc";
checkAbortIsReported(msc, root);
checkStackOverflowIsReported(msc, root);
console.log("GUARD-OK");
