// bug173 — the assert message is a call argument of the failure branch: unevaluated on the passing path, borrowed on the failing path

let bug173Calls: int32 = 0;

function bug173Message(): string {
	bug173Calls += 1;
	return "never built";
}

function bug173Make(): string {
	return "ab" + "c".repeat(2);
}

test "bug173: a passing assert never evaluates its message" {
	bug173Calls = 0;
	assert 1 == 1, bug173Message();
	assert bug173Calls === 0, "the message ran on the passing path";
}

test "bug173: a heap string local is a valid message" {
	const got = bug173Make();
	assert got === "abcc", got;
}

test "bug173: an arrow parameter is a valid message" {
	const check = (msg: string): void => {
		assert msg === "abcc", msg;
	};
	check(bug173Make());
}

test "bug173: a fresh concat is a valid message" {
	const got = bug173Make();
	assert got === "abcc", "got " + got;
}

test "bug173: a call result is a valid message" {
	const got = bug173Make();
	assert got === "abcc", bug173Make();
}
