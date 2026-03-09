// Test: match expression with value-type result variable
// matchLower generates `let x = undefined; if (...) x = value;`
// The `x = MS_NIL` default init must become `memset(&x, 0, sizeof(T))` for value types.

import { compileToC } from "../helpers";

test "match expr returning string emits zero init, not MS_NIL" {
	const src = `
enum Color { Red, Green, Blue }

function colorName(c: Color): string {
	const name = match (c) {
		Color.Red => "red",
		Color.Green => "green",
		_ => "blue",
	};
	return name;
}
`;
	const r = compileToC(src);
	assert r.ok;
	const code = r.value;
	// The match result variable should NOT be assigned MS_NIL (void* incompatible with msString)
	const hasNilAssign = code.contains("name = MS_NIL");
	assert !hasNilAssign;
}

test "match expr returning Result emits zero init" {
	const src = `
function tryParse(input: string): Result<number, string> {
	const r = match (input) {
		"yes" => Result.ok(1),
		"no" => Result.ok(0),
		_ => Result.err("unknown"),
	};
	return r;
}
`;
	const r = compileToC(src);
	assert r.ok;
	const code = r.value;
	const hasNilAssign = code.contains("r = MS_NIL");
	assert !hasNilAssign;
}
