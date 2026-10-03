enum GuardKind { A, B }

function guardedPick(kind: GuardKind, flag: boolean): string {
	return match (kind) { GuardKind.A when flag => "guarded", GuardKind.A => "plain", GuardKind.B => "other" };
}

function guardedBound(kind: GuardKind, flag: boolean): string {
	const picked: string = match (kind) {
		GuardKind.A when flag => "guarded",
		GuardKind.A => "plain",
		GuardKind.B => "other",
	};
	return picked;
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

test "matchDispatch: a match bound to a local picks the arm of a boolean value" {
	for (const flag of [true, false]) {
		const picked = match (flag) { true => "T", false => "F" };
		assert picked == (flag ? "T" : "F");
	}
}

test "matchDispatch: a match bound to a local accepts both boolean literals as alternatives" {
	for (const flag of [true, false]) {
		const picked = match (flag) { true | false => "any" };
		assert picked == "any";
	}
}

test "matchDispatch: a match bound to a local inspects the ok flag of a variant" {
	const good: Result<int32, string> = Result.ok(7 as int32);
	const bad: Result<int32, string> = Result.err("oops");
	const goodVerdict = match (good.ok) { true => "is-ok", false => "is-err" };
	const badVerdict = match (bad.ok) { true => "is-ok", false => "is-err" };
	assert goodVerdict == "is-ok";
	assert badVerdict == "is-err";
}

test "matchDispatch: a match bound to a local routes null apart from other values" {
	const present: string | null = "x";
	const absent: string | null = null as unknown as string | null;
	const presentVerdict = match (present) { null => "is-null", _ => "non-null" };
	const absentVerdict = match (absent) { null => "is-null", _ => "non-null" };
	assert presentVerdict == "non-null";
	assert absentVerdict == "is-null";
}

test "matchDispatch: a guarded pattern either wins once or falls through to its unguarded sibling" {
	for (const flag of [true, false]) {
		assert guardedPick(GuardKind.A, flag) == (flag ? "guarded" : "plain");
		assert guardedPick(GuardKind.B, flag) == "other";
		assert guardedEffect(GuardKind.A, flag) == 1;
		assert guardedEffect(GuardKind.B, flag) == 0;
	}
}

test "matchDispatch: a guarded pattern bound to a local keeps the value of the arm that won" {
	for (const flag of [true, false]) {
		assert guardedBound(GuardKind.A, flag) == (flag ? "guarded" : "plain");
		assert guardedBound(GuardKind.B, flag) == "other";
	}
}
