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
	const c = cFor("function f(t: string, a: int32, b: int32): int32 { const s: Readonly<Span<char>> = t[a..b]; return s.length as int32; }");
	assert c != "";
	assert c.contains("msSliceLen(");
}

test "an inclusive slice checks the end past its last element" {
	const c = cFor("function f(xs: int32[], a: int32, b: int32): int32 { const s: Span<int32> = xs[a...b]; return s.length as int32; }");
	assert c != "";
	assert c.contains("msSliceLen(a_p1, msAddI32(b_p2, 1), ");
}

test "a pointer slice checks its length against its own end" {
	const c = cFor("function f(p: Ptr<uint8>, a: int32, n: uint64): int64 { const s: Span<uint8> = p[a..n]; return s.length; }");
	assert c != "";
	assert c.contains("msSliceLen(a_p1, n_p2, n_p2)");
}

test "a pointer slice reads a computed end once" {
	const c = cFor("function f(p: Ptr<uint8>, n: uint64): int64 { const s: Span<uint8> = p[0..n - 1]; return s.length; }");
	assert c != "";
	const at = c.indexOf("msSliceLen(0ULL, ");
	assert at >= 0;
	const ends = c.slice(at + 17, c.indexOf(")", at)).split(", ");
	assert ends.length == 2 && ends[0] == ends[1] && ends[0].startsWith("__spansrc"), ends.join(" | ");
}
