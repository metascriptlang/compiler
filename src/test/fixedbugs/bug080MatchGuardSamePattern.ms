// bug080 — same-pattern guarded match arms ran the unguarded sibling too
//
// Symptom:    `K.A when f => x, K.A => y` with f=true produced y (assign
//             mode overwrote x) and ran BOTH bodies in stmt mode. In the
//             compiler itself this surfaced as a SIGSEGV: bridge.ms's
//             mapTypeToAstWith guard arm built a TypeUnion node that the
//             unguarded sibling immediately decref'd and overwrote.
// Root cause: matchLower buildSwitchDispatch grouped same-pattern arms into
//             one switch case but emitted sibling `if (guard) {body}` stmts
//             with EMPTY elses — the last unguarded body always ran.
// Fix:        chain the group's arms back-to-front as if/else-if/else
//             (first-match-wins), matching what buildIfChain already did.
//
// Guards use `when f` (no parens): `when (f) =>` hits a separate parser bug
// where the guard swallows `(f) => body` as an arrow function.

enum B80K { A, B }

let b80n: int32 = 0;
function b80bump(): void { b80n = b80n + 1; }

function b80pick(k: B80K, f: boolean): string {
	const r: string = match (k) {
		B80K.A when f => "A-guarded",
		B80K.A => "A-plain",
		B80K.B => "B",
	};
	return r;
}

function b80run(k: B80K, f: boolean): int32 {
	b80n = 0;
	match (k) {
		B80K.A when f => { b80bump(); },
		B80K.A => { b80bump(); },
		_ => {},
	};
	return b80n;
}

test "bug080: guard-true takes the guarded arm, not the sibling" {
	assert b80pick(B80K.A, true) == "A-guarded";
}

test "bug080: guard-false falls to the unguarded sibling" {
	assert b80pick(B80K.A, false) == "A-plain";
	assert b80pick(B80K.B, true) == "B";
}

test "bug080: stmt mode runs exactly one arm body" {
	assert b80run(B80K.A, true) == 1;
	assert b80run(B80K.A, false) == 1;
}
