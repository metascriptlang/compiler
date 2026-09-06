// bug048 — collectPass must not hoist test-block-local const/let to module scope
//
// Symptom:  A source file with two or more test blocks that reuse the same
//           local binding name (`const r = ...`) failed to compile with
//           "Duplicate symbol 'r'". This broke the self-hosted binary on most
//           of std (std/serialize/json/* have many such blocks) while the test
//           suite — run by a compiler built before the regression — stayed green.
//
// Root cause: collectPass recursed into every test-block statement and collected
//           local `const`/`let` declarations into MODULE scope. Sibling blocks
//           then collided. In TS/JS semantics only `function` declarations hoist;
//           `const`/`let` are block-scoped (temporal dead zone) and are handled
//           in-order by checkBlock's own scope — they never belong in the
//           forward-reference collector.
//
// Fix:      collectPass recurses into test blocks only for `FunctionDecl` (which
//           hoists and which codegen lifts to a top-level C function), skipping
//           block-local const/let.

test "bug048: sibling test block reuses local const name (block A)" {
	const r = 1 + 1;
	assert r == 2;
}

test "bug048: sibling test block reuses local const name (block B)" {
	const r = 3 + 4;
	assert r == 7;
}

test "bug048: same again with let" {
	let r = 10;
	r = r + 1;
	assert r == 11;
}
