import { compileToJS } from "../helpers";

test "an array element read is checked" {
	const result = compileToJS("function f(a: int32[], i: int32): int32 { return a[i]; }");
	assert result.ok;
	assert result.value.contains("a[msChkIndex(i, a.length)]");
}

test "a sized array element read is checked" {
	const result = compileToJS("function f(i: int32): int32 { const a: int32[3] = [1, 2, 3]; return a[i]; }");
	assert result.ok;
	assert result.value.contains("a[msChkIndex(i, a.length)]");
}

test "a span element read is checked through the view" {
	const result = compileToJS("function f(xs: Span<int32>, i: int32): int32 { return xs[i]; }");
	assert result.ok;
	assert result.value.contains("xs.base[(xs.off + msChkIndex(i, xs.len))]");
}

test "a span element write lands in the view's base" {
	const result = compileToJS("function f(xs: Span<int32>, i: int32): void { xs[i] = 5; }");
	assert result.ok;
	assert result.value.contains("xs.base[(xs.off + msChkIndex(i, xs.len))] = 5");
}

test "a span length reads the view" {
	const result = compileToJS("function f(xs: Span<int32>): int32 { return xs.length; }");
	assert result.ok;
	assert result.value.contains("xs.len");
}

test "an array passed as a span becomes a view" {
	const result = compileToJS("function f(xs: Span<int32>): int32 { return xs.length; } function g(a: int32[]): int32 { return f(a); }");
	assert result.ok;
	assert result.value.contains("msSpanOf(a)");
}

test "an array slice is a checked view" {
	const result = compileToJS("function f(xs: Span<int32>): int32 { return xs.length; } function g(a: int32[], s: int32, e: int32): int32 { return f(a[s..e]); }");
	assert result.ok;
	assert result.value.contains("msSliceOf(a, s, e)");
}

test "an inclusive slice passes the end past the last element" {
	const result = compileToJS("function f(xs: Span<int32>): int32 { return xs.length; } function g(a: int32[], s: int32, e: int32): int32 { return f(a[s...e]); }");
	assert result.ok;
	assert result.value.contains("msSliceOf(a, s, (e + 1))");
}

test "a slice of a span rebases the view" {
	const result = compileToJS("function f(xs: Span<int32>): int32 { return xs.length; } function g(v: Span<int32>): int32 { return f(v[1..2]); }");
	assert result.ok;
	assert result.value.contains("msSliceSpan(v, 1, 2)");
}

test "an element write checks the index against the array it writes" {
	const result = compileToJS("function f(a: int32[], i: int32): void { a[i] = 5; }");
	assert result.ok;
	assert result.value.contains("a[msChkIndex(i, a.length)] = 5");
}

test "an element update checks the index" {
	const result = compileToJS("function f(a: int32[], i: int32): void { a[i]++; }");
	assert result.ok;
	assert result.value.contains("a[msChkIndex(i, a.length)]++");
}

test "a write into a computed array checks through the array once" {
	const result = compileToJS("function g(): int32[] { return [1]; } function f(i: int32): void { g()[i] = 5; }");
	assert result.ok;
	assert result.value.contains("[i] = 5");
	assert result.value.contains("msChkArray(");
}

test "a write with a computed array and a computed index is refused" {
	const result = compileToJS("function g(): int32[] { return [1]; } function h(): int32 { return 0; } function f(): void { g()[h()] = 5; }");
	assert !result.ok;
	assert result.error.contains("hoist the array or the index into a local first");
}

test "a read with a computed array and a computed index goes through the read helper" {
	const result = compileToJS("function g(): int32[] { return [1]; } function h(): int32 { return 0; } function f(): int32 { return g()[h()]; }");
	assert result.ok;
	assert result.value.contains("msArrayAt(g");
}

test "a value struct read through the read helper is copied" {
	const result = compileToJS("struct P { n: int32; } function g(): P[] { return [{ n: 1 }]; } function h(): int32 { return 0; } function f(): P { const p = g()[h()]; return p; }");
	assert result.ok;
	assert result.value.contains("msValCopy_");
}
