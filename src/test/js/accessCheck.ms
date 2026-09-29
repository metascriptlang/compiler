import { compileToJS } from "../helpers";

test "an array element read is checked" {
	const result = compileToJS("function f(a: int32[], i: int32): int32 { return a[i]; }");
	assert result.ok;
	assert result.value.contains("msArrayAt(a, i)");
}

test "a sized array element read is checked" {
	const result = compileToJS("function f(i: int32): int32 { const a: int32[3] = [1, 2, 3]; return a[i]; }");
	assert result.ok;
	assert result.value.contains("msArrayAt(a, i)");
}

test "a span element read is checked" {
	const result = compileToJS("function f(xs: Span<int32>, i: int32): int32 { return xs[i]; }");
	assert result.ok;
	assert result.value.contains("msArrayAt(xs, i)");
}

test "an element write checks the index against the array it writes" {
	const result = compileToJS("function f(a: int32[], i: int32): void { a[i] = 5; }");
	assert result.ok;
	assert result.value.contains("a[msChkIndex(i, a.length)] = 5");
}

test "an element update checks the index" {
	const result = compileToJS("function f(a: int32[], i: int32): void { a[i]++; }");
	assert result.ok;
	assert result.value.contains("msChkIndex(i, a.length)");
	assert !result.value.contains("msArrayAt(a, i)++");
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
