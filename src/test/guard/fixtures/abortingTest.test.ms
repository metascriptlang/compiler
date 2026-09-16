// Fixture for src/test/guard/testRunnerReportsSignal.ms — NOT part of any suite. The test kills its own process.

extern function abort(): void;

test "the test binary dies by SIGABRT" {
	abort();
}
