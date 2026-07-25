// Fixture for src/test/guard/testBoundaryReportsEscape.ms — NOT part of any suite.
// This file is EXPECTED TO FAIL when compiled + run by the msc under test:
// the throw escapes the test body, so the test never completes and must be
// reported as a failure. Do not "fix" it.

function boom(v: number): number {
	throw new Error("boom");
}

test "an uncaught throw must be reported as a failure" {
	const r = boom(1);
	assert r === 999, "unreachable — the throw escapes before this runs";
}
