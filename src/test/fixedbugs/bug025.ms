// bug025 — match patterns: true/false/null treated as binding names
//
// Symptom:    `match (b: boolean) { true => "T", false => "F" }` always
//             returned "T" regardless of b's value. Same for null patterns.
//
// Root cause: Parser at src/parser/expressions/match.ms:163-170 lumped
//             TokenKind.True / .False / .Null with isIdentLike into a single
//             branch that wraps the token as `Identifier(name="true"/"false"/"null")`.
//             matchLower's isBindingPattern treats any unresolved Identifier
//             (other than `_`) as a binding pattern, emitting unconditional
//             `const true_ = $match;` + body. Later arms overwrite earlier
//             via reverse-loop in buildIfChain.
//
// Fix:        Parser dispatches True/False/Null tokens to proper literal
//             nodes (BooleanLiteral / NullLiteral) BEFORE the isIdentLike
//             branch. Shared helper `tryParseLiteralKeyword` in
//             expressions/util.ms used by both core.ms and match.ms to avoid
//             duplication.
//
// Why latent: Type-level boolean DUs (`type X = match (ok: boolean) { ... }`)
//             use a different parser path (typeAnnotation.ms) and worked.
//             Expression-level boolean match was untested at runtime — only
//             parser smoke test ("bool patterns" at match.ms:187) verified
//             parse-without-crash, not dispatch correctness.
//
// Discovered: SERIALIZE V3 phase B-1 (JSON encode Union branch) needed
//             `match (e.<discField>) { true => ..., false => ... }` for
//             generic DU support — first real expression-level boolean match.

test "bug025: match boolean — true arm dispatches" {
	const b: boolean = true;
	const out = match (b) { true => "T", false => "F" };
	assert out == "T";
}

test "bug025: match boolean — false arm dispatches" {
	const b: boolean = false;
	const out = match (b) { true => "T", false => "F" };
	assert out == "F";
}

test "bug025: match Result.ok — true variant" {
	const r: Result<int32, string> = Result.ok(7 as int32);
	const out = match (r.ok) { true => "is-ok", false => "is-err" };
	assert out == "is-ok";
}

test "bug025: match Result.ok — false variant" {
	const r: Result<int32, string> = Result.err("oops");
	const out = match (r.ok) { true => "is-ok", false => "is-err" };
	assert out == "is-err";
}

test "bug025: match null pattern — non-null branch" {
	const n: string | null = "x";
	const out = match (n) { null => "is-null", _ => "non-null" };
	assert out == "non-null";
}

test "bug025: match null pattern — null branch" {
	const n: string | null = null as unknown as string | null;
	const out = match (n) { null => "is-null", _ => "non-null" };
	assert out == "is-null";
}

test "bug025: or-pattern with boolean literals" {
	const b1: boolean = true;
	const b2: boolean = false;
	const out1 = match (b1) { true | false => "any" };
	const out2 = match (b2) { true | false => "any" };
	assert out1 == "any";
	assert out2 == "any";
}
