// Parked at inbox card 2026-10-09-null-compare-on-narrowed-nullable-number-fails-clang.md

function returnPrim(b: boolean): number | null {
	if (b) return 42;
	return null;
}

test "function returning primitive | null with value" {
	const r = returnPrim(true);
	assert r != null;
	if (r != null) assert r == 42;
}

test "assign primitive value to mutable Maybe<T> variable" {
	let x: number | null = null;
	assert x == null;
	x = 42;
	assert x != null;
	if (x != null) assert x == 42;
}
