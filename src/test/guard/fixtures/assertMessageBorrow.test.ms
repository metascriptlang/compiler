// Fixture for src/test/guard/assertMessageBorrow.ms — NOT part of any suite. The assert is meant to fail.

function make(): string { return "ab" + "c".repeat(2); }

test "a failing assert whose message is a local heap string" {
	const got = make();
	assert got === "zzz", got;
}
