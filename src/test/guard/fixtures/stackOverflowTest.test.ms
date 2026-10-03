// Fixture for src/test/guard/testRunnerReportsSignal.ms — NOT part of any suite. The test overflows its own stack.

function deeper(n: int32): int32 {
	return deeper(n + 1) + 1;
}

test "the test binary overflows its stack" {
	assert deeper(0) > 0;
}
