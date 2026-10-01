import { compileToC } from "../helpers";

function cFor(body: string): string {
	const c = compileToC(body);
	if (!c.ok) return "";
	return c.value;
}

test "a slice of a dynamic array checks its bounds" {
	const c = cFor("function f(xs: int32[], a: int32, b: int32): int32 { const s: Span<int32> = xs[a..b]; return s.length as int32; }");
	assert c != "";
	assert c.contains("msSliceLen(");
}

test "a slice of a sized array checks its bounds against N" {
	const c = cFor("function f(a: int32, b: int32): int32 { let xs: int32[4] = [1, 2, 3, 4]; const s: Span<int32> = xs[a..b]; return s.length as int32; }");
	assert c != "";
	assert c.contains("msSliceLen(");
	assert c.contains(", 4)");
}

test "a slice of a span checks its bounds" {
	const c = cFor("function f(xs: Span<int32>, a: int32, b: int32): int32 { const s: Span<int32> = xs[a..b]; return s.length as int32; }");
	assert c != "";
	assert c.contains("msSliceLen(");
}

test "a slice of a string checks its bounds" {
	const c = cFor("function f(t: string, a: int32, b: int32): int32 { const s: Span<char> = t[a..b]; return s.length as int32; }");
	assert c != "";
	assert c.contains("msSliceLen(");
}

test "an inclusive slice checks the end past its last element" {
	const c = cFor("function f(xs: int32[], a: int32, b: int32): int32 { const s: Span<int32> = xs[a...b]; return s.length as int32; }");
	assert c != "";
	assert c.contains("msSliceLen(");
	assert c.contains(" + 1");
}
