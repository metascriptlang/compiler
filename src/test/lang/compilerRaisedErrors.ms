test "compiler raises: array iteration defects carry a message and stop at the mutation" {
	const values: string[] = ["a", "b"];
	let visited: int32 = 0;
	let message = "";
	try {
		for (const value of values) {
			visited += 1;
			values.pop();
		}
	} catch (error) {
		message = error.message;
	}
	assert visited == 1;
	assert message.contains("length") && message.contains("array");
}

test "compiler raises: string iteration defects carry a message and stop at the mutation" {
	let text = "ab";
	let visited: int32 = 0;
	let message = "";
	try {
		for (const value of text) {
			visited += 1;
			text = text + "c";
		}
	} catch (error) {
		message = error.message;
	}
	assert visited == 1;
	assert message.contains("length") && message.contains("string");
}

