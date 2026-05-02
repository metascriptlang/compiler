// Language tests: JSON stringify + untyped parse via JsonValue accessors.
//
// Runtime caveat: JSON.parse<T> (typed) is a C-backend-only feature — the
// checker synthesizes per-type `__jsonParse_T` helpers that the Bun
// transpiler doesn't reproduce. Typed-parse coverage lives in
// `src/test/c/json.ms` (compile-check). Here we exercise the paths that
// work uniformly across backends.

interface Person {
	name: string;
	age: int32;
}

test "JSON.stringify typed struct" {
	const p: Person = { name: "Alice", age: 30 };
	const s = JSON.stringify(p);
	assert s === `{"name":"Alice","age":30}`;
}

test "JSON.stringify inline anonymous literal" {
	const s = JSON.stringify({ field: "value" });
	assert s === `{"field":"value"}`;
}

test "JSON.stringify nested literal" {
	const s = JSON.stringify({ a: 1, b: { c: 2 } });
	assert s === `{"a":1,"b":{"c":2}}`;
}

