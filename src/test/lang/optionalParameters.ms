// `x?: T` is `x: T | null = null`: the omitted-argument fill of a call through a value of function type.
// Sibling coverage: src/parser/util.ms tests (grammar and refusals), corpus/programs/optionalParameters.ms (all lanes).

class Pt { x: int32 = 4; }

function read(xs?: number[]): number { return xs == null ? -1 : xs.length; }

test "a function declaration may be called without its optional argument" {
	assert read() == -1;
	assert read([1, 2]) == 2;
}

test "a value of function type fills an omitted optional argument with null" {
	const f: (xs?: number[]) => number = read;
	assert f() == -1;
	assert f([1, 2, 3]) == 3;
}

test "an optional value-typed argument fills with null" {
	const g: (n?: int32) => int32 = (n?: int32): int32 => n == null ? -1 : n;
	assert g() == -1;
	assert g(0) == 0;
}

test "an optional class-typed argument fills with null" {
	const g: (p?: Pt) => int32 = (p?: Pt): int32 => p == null ? -1 : p.x;
	assert g() == -1;
	assert g(new Pt()) == 4;
}

test "a required parameter before an optional one stays required" {
	const g: (a: int32, b?: string) => string = (a: int32, b?: string): string => b == null ? `${a}` : b;
	assert g(1) == "1";
	assert g(1, "z") == "z";
}

test "an unannotated arrow with an optional parameter may be called without it" {
	const g = (s?: string): string => s == null ? "none" : s;
	assert g() == "none";
	assert g("a") == "a";
}

function pick<T>(x?: T): boolean { return x != null; }

test "a generic optional parameter fills with null for a value type and a class" {
	assert !pick<int32>();
	assert pick<int32>(2);
	assert !pick<Pt>();
	assert pick<Pt>(new Pt());
}
