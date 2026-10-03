// The test runner names the signal that killed a test binary instead of exiting 255 in silence
// Run as `./msc test src/test/guard/testRunnerReportsSignal.ms` from the recompiler root.

import { execFileCapture, cwd, platform } from "std/process";

test "a test binary killed by SIGABRT is reported with its signal" {
	const root = cwd();
	const r = execFileCapture(root + "/msc", ["test", root + "/src/test/guard/fixtures/abortingTest.test.ms"]);
	assert !r.ok, "a killed test binary must not read as a pass";
	if (!r.ok) {
		assert r.error.exitCode === 134, "msc test exited " + r.error.exitCode.toString() + "\n" + r.error.output + r.error.errorOutput;
		assert r.error.output.contains("terminated by signal 6"), "no signal report\n" + r.error.output + r.error.errorOutput;
	}
}

test "a test binary that overflows its stack is reported and fails" {
	const root = cwd();
	const r = execFileCapture(root + "/msc", ["test", root + "/src/test/guard/fixtures/stackOverflowTest.test.ms"]);
	assert !r.ok, "a crashed test binary must not read as a pass";
	if (!r.ok) {
		const want = platform == "windows" ? "terminated with status 0xC00000FD" : "terminated by signal 11";
		assert r.error.output.contains(want), "no crash report\n" + r.error.output + r.error.errorOutput;
	}
}
