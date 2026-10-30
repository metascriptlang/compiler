interface QuotedDeclaredSource { x: string; y: int32; }

function readQuotedPattern({ "x": text, "y": count }: QuotedDeclaredSource): int32 {
	return text.length + count;
}

test "quoted direct parameter bindings use checked stored fields" {
	assert readQuotedPattern({ x: "yes", y: 7 }) == 10;
}

test "quoted direct for-of bindings use checked element fields" {
	const values: QuotedDeclaredSource[] = [{ x: "a", y: 2 }, { x: "bb", y: 3 }];
	let total: int32 = 0;
	for (const { "x": text, "y": count } of values) {
		total += text.length + count;
	}
	assert total == 8;
}

test "quoted declaration bindings use their retained declared type" {
	const source: QuotedDeclaredSource = { x: "yes", y: 7 };
	const { "x": text, "y": count }: QuotedDeclaredSource = source;
	assert text == "yes";
	assert count == 7;
}

test "quoted object bindings preserve key identity and evaluate the source once" {
	let calls: int32 = 0;
	const make = () => {
		calls += 1;
		return { "data-probe": 7, other: 9 };
	};
	const { "data-probe": value } = make();
	assert value == 7;
	assert calls == 1;
}

test "quoted object binding defaults do not evaluate a present fallback" {
	let calls: int32 = 0;
	const fallback = () => { calls += 1; return 11; };
	const source = { "data-probe": 7 };
	const { "data-probe": value = fallback() } = source;
	assert value == 7;
	assert calls == 0;
}

test "quoted object binding defaults retain the existing single-null absence contract" {
	let calls: int32 = 0;
	const fallback = () => { calls += 1; return 11; };
	const source = { "data-probe": null as (int32 | null) };
	const { "data-probe": value = fallback() } = source;
	assert value == 11;
	assert calls == 1;
}

test "quoted object binding rest preserves distinct escaped field names" {
	const source = { "a-b": 3, a_b: 4, other: 5 };
	const { "a-b": first, ...rest } = source;
	assert first == 3;
	assert rest.a_b == 4;
	assert rest.other == 5;
}

test "quoted object bindings retain decoded punctuation unicode and empty keys" {
	const source = {
		"a\"b": 1, "slash\\path": 2, "đèn": 3, "a:b;c,d": 4, "": 5,
	};
	const {
		"a\"b": quote, "slash\\path": slash, "đèn": unicode,
		"a:b;c,d": punctuation, "": empty,
	} = source;
	assert quote == 1;
	assert slash == 2;
	assert unicode == 3;
	assert punctuation == 4;
	assert empty == 5;
}
