let messageCalls: int32 = 0;

function note(s: string): string { messageCalls++; return s; }

function parse(text: string): Result<string, string> {
	if (text.length == 0) return Result.err("empty");
	return Result.ok(text);
}

test "assertMessageLazy: a ternary message of a passing assert is not evaluated" {
	messageCalls = 0;
	const k = 1;
	assert k == 1, k > 0 ? note("ternary") : "b";
	assert messageCalls == 0;
}

test "assertMessageLazy: a short-circuit message of a passing assert is not evaluated" {
	messageCalls = 0;
	const k = 1;
	assert k == 1, "p" + (k > 0 && note("and") == "and" ? "y" : "n");
	assert k == 1, k < 0 || note("or") == "or" ? "y" : "n";
	assert messageCalls == 0;
}

test "assertMessageLazy: the message stays unevaluated inside a loop and a nested function" {
	messageCalls = 0;
	const check = (n: int32): void => {
		for (let i = 0; i < n; i++) {
			assert i < n, i > 0 ? note("loop") : note("first");
		}
	};
	check(3);
	assert messageCalls == 0;
}

test "assertMessageLazy: a message reading the narrowed ok variant runs" {
	const r = parse("abc");
	assert r.ok, r.ok ? "" : r.error;
	assert r.value == "abc";
	const e = parse("");
	assert !e.ok && e.error == "empty", e.ok ? "" : e.error;
}
