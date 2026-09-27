enum GuardKind { A, B }

function guardedPick(kind: GuardKind, flag: boolean): string {
	return match (kind) { GuardKind.A when flag => "guarded", GuardKind.A => "plain", GuardKind.B => "other" };
}

function guardedEffect(kind: GuardKind, flag: boolean): int32 {
	let hits: int32 = 0;
	match (kind) {
		GuardKind.A when flag => { hits++; },
		GuardKind.A => { hits++; },
		_ => {},
	};
	return hits;
}

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

test "matchDispatch: a guarded pattern either wins once or falls through to its unguarded sibling" {
	for (const flag of [true, false]) {
		assert guardedPick(GuardKind.A, flag) == (flag ? "guarded" : "plain");
		assert guardedPick(GuardKind.B, flag) == "other";
		assert guardedEffect(GuardKind.A, flag) == 1;
		assert guardedEffect(GuardKind.B, flag) == 0;
	}
}
