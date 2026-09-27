function maybeInt(value: int32, present: boolean): int32 | null {
	return present ? value : null;
}

function maybeText(value: string, present: boolean): string | null {
	return present ? value : null;
}

interface EqualityReads { count: int32; }

function next(this reads: EqualityReads): int32 | null {
	reads.count += 1;
	return 3;
}

test "carrier equality: presence and payload jointly determine equality" {
	for (const value of [-1, 0, 7]) {
		assert !(maybeInt(value, false) == value);
		assert !(value == maybeInt(value, false));
		assert maybeInt(value, false) != value;
		assert maybeInt(value, true) == value;
		assert value == maybeInt(value, true);
		assert !(maybeInt(value, true) != value);
		assert maybeInt(value, true) != value + 1;
		assert maybeInt(value, false) == maybeInt(value + 1, false);
		assert !(maybeInt(value, false) == maybeInt(value, true));
	}
	for (const text of ["", "a", "payload"]) {
		assert !(maybeText(text, false) == text);
		assert maybeText(text, false) != text;
		assert maybeText(text, true) == text;
		assert maybeText(text, true) != text + "!";
	}
}

test "carrier equality: bare call operands are evaluated once" {
	const reads: EqualityReads = { count: 0 };
	assert reads.next() == 3;
	assert reads.count == 1;
	assert 3 == reads.next();
	assert reads.count == 2;
	const values = new Map<string, int32>();
	values.set("key", 3);
	assert values.get("key") == 3;
	assert values["key"] == 3;
	assert values.get("missing") != 0;
}

test "carrier equality: unwrapped map callbacks preserve their callable payload" {
	const callbacks = new Map<string, (a: int32, b: int32) => int32>();
	callbacks.set("min", (a, b) => (a < b ? a : b) as int32);
	const compare = callbacks.get("min")!;
	assert compare(3, 7) == 3;
	assert compare(9, 4) == 4;
}
