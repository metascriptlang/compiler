// Parked at inbox card 2026-09-27-match-expression-contexts.md

test "matchDispatch: boolean patterns and alternatives dispatch exhaustively" {
	for (const flag of [true, false]) {
		assert (match (flag) { true => "T", false => "F" }) == (flag ? "T" : "F");
		assert (match (flag) { true | false => "any" }) == "any";
	}
}

test "matchDispatch: variant and nullable patterns inspect their carriers" {
	const values: Result<int32, string>[] = [Result.ok(7), Result.err("oops")];
	for (let i: int32 = 0; i < values.length; i++) {
		const value = values[i];
		assert (match (value.ok) { true => "is-ok", false => "is-err" }) == (i == 0 ? "is-ok" : "is-err");
	}
	const valuesOrNull: (string | null)[] = ["x", null];
	for (let i: int32 = 0; i < valuesOrNull.length; i++) {
		const value = valuesOrNull[i];
		assert (match (value) { null => "is-null", _ => "non-null" }) == (i == 0 ? "non-null" : "is-null");
	}
}
