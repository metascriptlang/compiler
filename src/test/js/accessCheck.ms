import { compileToJSBare } from "../helpers";

test "an array element read is checked" {
	const result = compileToJSBare("function f(a: int32[], i: int32): int32 { return a[i]; }");
	assert result.ok;
	assert result.value.contains("a[(((i >= 0) && (i < a.length)) ? i : msIndexFail(i, a.length))]");
}

test "a for-of element read is not checked, the length guard after each element stays" {
	const result = compileToJSBare("function f(xs: int32[]): int32 { let t: int32 = 0; for (const x of xs) { t = t ^ x; } return t; }");
	assert result.ok;
	assert !result.value.contains("msIndexFail"), result.value;
	assert result.value.contains("the length of the array changed while iterating over it"), result.value;
}

test "a for-of element read of a span keeps the view offset and drops only the check" {
	const result = compileToJSBare("function f(xs: Span<int32>): int32 { let t: int32 = 0; for (const x of xs) { t = t ^ x; } return t; }");
	assert result.ok;
	assert !result.value.contains("msIndexFail"), result.value;
	assert result.value.contains("xs.base[(xs.off + "), result.value;
}

test "a for-of over a string has no length guard" {
	const result = compileToJSBare("function f(s: string): int32 { let t: int32 = 0; for (const c of s) { t = t ^ (c as int32); } return t; }");
	assert result.ok;
	assert !result.value.contains("the length of the string changed"), result.value;
}

test "a sized array element read is checked" {
	const result = compileToJSBare("function f(i: int32): int32 { const a: int32[3] = [1, 2, 3]; return a[i]; }");
	assert result.ok;
	assert result.value.contains("a[(((i >= 0) && (i < a.length)) ? i : msIndexFail(i, a.length))]");
}

test "a constant index into a sized array is not checked, on a read and on a write" {
	const result = compileToJSBare("function f(): int32 { let a: int32[3] = [1, 2, 3]; a[1] = 5; return a[2]; }");
	assert result.ok;
	assert !result.value.contains("msIndexFail"), result.value;
	assert result.value.contains("a[1] = 5"), result.value;
	assert result.value.contains("return a[2]"), result.value;
}

test "a constant index into a growable array is checked" {
	const result = compileToJSBare("function f(a: int32[]): int32 { return a[2]; }");
	assert result.ok;
	assert result.value.contains("msIndexFail(2, a.length)"), result.value;
}

test "a uint8 index into a sized array of 256 is not checked" {
	const result = compileToJSBare("function f(t: uint32[256], b: uint8): uint32 { return t[b]; }");
	assert result.ok;
	assert !result.value.contains("msIndexFail"), result.value;
	assert result.value.contains("return t[b]"), result.value;
}

test "a uint8 index into a sized array of 255 is checked" {
	const result = compileToJSBare("function f(t: uint32[255], b: uint8): uint32 { return t[b]; }");
	assert result.ok;
	assert result.value.contains("msIndexFail(b, t.length)"), result.value;
}

test "an int8 index into a sized array of 256 is checked" {
	const result = compileToJSBare("function f(t: uint32[256], b: int8): uint32 { return t[b]; }");
	assert result.ok;
	assert result.value.contains("msIndexFail(b, t.length)"), result.value;
}

test "a span element read is checked through the view" {
	const result = compileToJSBare("function f(xs: Span<int32>, i: int32): int32 { return xs[i]; }");
	assert result.ok;
	assert result.value.contains("xs.base[(xs.off + (((i >= 0) && (i < xs.len)) ? i : msIndexFail(i, xs.len)))]");
}

test "a span element write lands in the view's base" {
	const result = compileToJSBare("function f(xs: Span<int32>, i: int32): void { xs[i] = 5; }");
	assert result.ok;
	assert result.value.contains("xs.base[(xs.off + (((i >= 0) && (i < xs.len)) ? i : msIndexFail(i, xs.len)))] = 5");
}

test "a span length reads the view" {
	const result = compileToJSBare("function f(xs: Span<int32>): int32 { return xs.length; }");
	assert result.ok;
	assert result.value.contains("xs.len");
}

test "an array passed as a span becomes a view" {
	const result = compileToJSBare("function f(xs: Span<int32>): int32 { return xs.length; } function g(a: int32[]): int32 { return f(a); }");
	assert result.ok;
	assert result.value.contains("msSpanOf(a)");
}

test "an array slice is a checked view" {
	const result = compileToJSBare("function f(xs: Span<int32>): int32 { return xs.length; } function g(a: int32[], s: int32, e: int32): int32 { return f(a[s..e]); }");
	assert result.ok;
	assert result.value.contains("msSliceOf(a, s, e)");
}

test "an inclusive slice passes the end past the last element" {
	const result = compileToJSBare("function f(xs: Span<int32>): int32 { return xs.length; } function g(a: int32[], s: int32, e: int32): int32 { return f(a[s...e]); }");
	assert result.ok;
	assert result.value.contains("msSliceOf(a, s, ((($int_0 = (e + 1)) === ($int_0 | 0)) ? $int_0 : msOverflowI32($int_0)))");
}

test "a slice of a span rebases the view" {
	const result = compileToJSBare("function f(xs: Span<int32>): int32 { return xs.length; } function g(v: Span<int32>): int32 { return f(v[1..2]); }");
	assert result.ok;
	assert result.value.contains("msSliceSpan(v, 1, 2)");
}

test "an element write checks the index against the array it writes" {
	const result = compileToJSBare("function f(a: int32[], i: int32): void { a[i] = 5; }");
	assert result.ok;
	assert result.value.contains("a[(((i >= 0) && (i < a.length)) ? i : msIndexFail(i, a.length))] = 5");
}

test "an element update checks the index" {
	const result = compileToJSBare("function f(a: int32[], i: int32): void { a[i]++; }");
	assert result.ok;
	assert result.value.contains("a[(((i >= 0) && (i < a.length)) ? i : msIndexFail(i, a.length))] = ((($int_0 = (a[(((i >= 0) && (i < a.length)) ? i : msIndexFail(i, a.length))] + 1)) === ($int_0 | 0)) ? $int_0 : msOverflowI32($int_0))");
}

test "a write into a computed array checks through the array once" {
	const result = compileToJSBare("function g(): int32[] { return [1]; } function f(i: int32): void { g()[i] = 5; }");
	assert result.ok;
	assert result.value.contains("[i] = 5");
	assert result.value.contains("msChkArray(");
}

test "a write with a computed array and a computed index holds the array in a temporary" {
	const result = compileToJSBare("function g(): int32[] { return [1]; } function h(): int32 { return 0; } function f(): void { g()[h()] = 5; g()[h()] += 1; g()[h()]++; }");
	assert result.ok;
	const at = result.value.indexOf("var $place_") + 4;
	assert at >= 4;
	const place = result.value.slice(at, result.value.indexOf(" ", at));
	assert result.value.contains("(" + place + " = g");
	assert result.value.contains(place + ".length))] = 5");
	assert !result.value.contains("msArrayAt(");
}

test "a read with a computed array and a computed index goes through the read helper" {
	const result = compileToJSBare("function g(): int32[] { return [1]; } function h(): int32 { return 0; } function f(): int32 { return g()[h()]; }");
	assert result.ok;
	assert result.value.contains("msArrayAt(g");
}

test "a value struct read through the read helper is copied" {
	const result = compileToJSBare("struct P { n: int32; } function g(): P[] { return [{ n: 1 }]; } function h(): int32 { return 0; } function f(): P { const p = g()[h()]; return p; }");
	assert result.ok;
	assert result.value.contains("msValCopy_");
}

test "a span element passed to an out parameter is a checked cell of the view's base" {
	const result = compileToJSBare("function set(out v: int32): void { v = 1; } function f(xs: Span<int32>, i: int32): void { set(xs[i]); }");
	assert result.ok;
	assert result.value.contains("msSpanCell(xs, i)");
}

test "an array element passed to an out parameter is a checked cell" {
	const result = compileToJSBare("function set(out v: int32): void { v = 1; } function f(xs: int32[], i: int32): void { set(xs[i]); }");
	assert result.ok;
	assert result.value.contains("msArrayCell(xs, i)");
}

test "a spread span copies the view's elements" {
	const result = compileToJSBare("function f(xs: Span<int32>): int32[] { return [...xs]; }");
	assert result.ok;
	assert result.value.contains("...msSpanValues(xs)");
}

test "a string passed as a span is its byte view" {
	const result = compileToJSBare("function n(xs: Readonly<Span<char>>): int32 { return xs.length; } function f(s: string): int32 { return n(s) + n(s[1..2]); }");
	assert result.ok;
	assert result.value.contains("msSliceSpan(asBytes(s), 1, 2)");
	assert !result.value.contains("msSpanOf(asBytes(");
}

test "a computed index is held once in a temporary assigned inside the test" {
	const result = compileToJSBare("function f(a: int32[], i: int32): int32 { return a[i + 1]; }");
	assert result.ok;
	assert result.value.contains("var $idx_");
	assert result.value.contains(" = ((($int_0 = (i + 1)) === ($int_0 | 0)) ? $int_0 : msOverflowI32($int_0))) >= 0)");
	assert !result.value.contains("msChkIndex(");
}

test "a 64-bit index is narrowed to a number only on the in-range path" {
	const result = compileToJSBare("function f(a: int32[], j: int64): int32 { return a[j]; }");
	assert result.ok;
	assert result.value.contains("? globalThis.Number(j) : msIndexFail(j, a.length))");
}

test "an int32 sum is range-tested inline and only a value out of range calls msOverflowI32" {
	const result = compileToJSBare("function f(a: int32, b: int32): int32 { return a + b; }");
	assert result.ok;
	assert result.value.contains("return ((($int_0 = (a + b)) === ($int_0 | 0)) ? $int_0 : msOverflowI32($int_0));"), result.value;
}

test "under a for with literal bounds a counter index that stays inside a sized array has no index or overflow check" {
	const result = compileToJSBare("function f(w: uint32[64]): uint32 { let t: uint32 = 0; for (let i = 16; i < 64; i++) { t = t ^ w[i - 15] ^ w[i] ^ w[i * 1 + 0]; } return t; }");
	assert result.ok;
	assert !result.value.contains("msIndexFail"), result.value;
	assert !result.value.contains("msOverflowI32"), result.value;
	assert result.value.contains("w[(i - 15)]"), result.value;
}

test "a counter index that can pass the end of the sized array is checked" {
	const result = compileToJSBare("function f(w: uint32[64]): uint32 { let t: uint32 = 0; for (let i = 0; i < 65; i++) { t = t ^ w[i]; } return t; }");
	assert result.ok;
	assert result.value.contains("msIndexFail(i, w.length)"), result.value;
}

test "a counter index that can go below zero is checked" {
	const result = compileToJSBare("function f(w: uint32[64]): uint32 { let t: uint32 = 0; for (let i = 16; i < 64; i++) { t = t ^ w[i - 17]; } return t; }");
	assert result.ok;
	assert result.value.contains("msIndexFail"), result.value;
}

test "a counter the body writes proves nothing" {
	const result = compileToJSBare("function f(w: uint32[64]): uint32 { let t: uint32 = 0; for (let i = 0; i < 64; i++) { i = i + 1; t = t ^ w[i]; } return t; }");
	assert result.ok;
	assert result.value.contains("msIndexFail"), result.value;
}

test "a bound that is not a literal proves nothing" {
	const result = compileToJSBare("function f(w: uint32[64], n: int32): uint32 { let t: uint32 = 0; for (let i = 0; i < n; i++) { t = t ^ w[i]; } return t; }");
	assert result.ok;
	assert result.value.contains("msIndexFail(i, w.length)"), result.value;
}

test "a closure in the loop body keeps its check" {
	const result = compileToJSBare("function f(w: uint32[64]): uint32 { let t: uint32 = 0; for (let i = 0; i < 64; i++) { const g = (): uint32 => w[i]; t = t ^ g(); } return t; }");
	assert result.ok;
	assert result.value.contains("msChkIndex(i, w.length)"), result.value;
}

test "counter arithmetic that can leave int32 keeps its overflow check" {
	const result = compileToJSBare("function f(): int32 { let t: int32 = 0; for (let i = 0; i < 64; i++) { t = i * 100000000; } return t; }");
	assert result.ok;
	assert result.value.contains("msOverflowI32"), result.value;
}

test "two nested counters prove an index built from both" {
	const result = compileToJSBare("function f(w: uint32[64]): uint32 { let t: uint32 = 0; for (let i = 0; i < 8; i++) { for (let j = 0; j < 8; j++) { t = t ^ w[i * 8 + j]; } } return t; }");
	assert result.ok;
	assert !result.value.contains("msIndexFail"), result.value;
	assert !result.value.contains("msOverflowI32"), result.value;
}

test "an index converted from a number to int64 is checked as the truncated double, not a BigInt" {
	const result = compileToJSBare("function f(xs: int32[], k: number): int32 { return xs[k as int64]; }");
	assert result.ok;
	assert result.value.contains("Math.trunc(msCheckRangeI64(k))"), result.value;
	assert !result.value.contains("BigInt("), result.value;
}
