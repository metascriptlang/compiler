// Fixture for src/test/guard/assertInTryFails.ms — NOT part of any suite. The assert is meant to fail.

test "a failing assert inside try fails the test" {
	let caught = false;
	try {
		assert 1 == 2, "boom";
	} catch (e) {
		caught = true;
	}
	assert caught, "the catch ran";
}
