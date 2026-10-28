// Checker — `x[a..b]` slices an array, a Span, a string or a typed pointer

import { strictErrorCount, hasError } from "./helpers";

const NO_SLICE = "only an array, a Span, a string or a typed pointer can be sliced";

test "an array, a sized array, a Span and a string slice" {
	assert strictErrorCount("function f(a: int32[]): int64 { return a[0..2].length; }") == 0;
	assert strictErrorCount("function f(): int64 { const a: int32[4] = [1, 2, 3, 4]; return a[1...3].length; }") == 0;
	assert strictErrorCount("function f(xs: Span<int32>): int64 { return xs[1..2].length; }") == 0;
	assert strictErrorCount("function f(s: string): int64 { return s[0..3].length; }") == 0;
	assert strictErrorCount("function f<T>(xs: T): int64 { return xs[0..2].length; }") == 0;
}

test "a typed pointer slices into a Span whatever the integer type of its end" {
	assert strictErrorCount("function f(p: Ptr<uint8>, n: uint64): int64 { const v: Span<uint8> = p[0..n]; return v.length; }") == 0;
	assert strictErrorCount("function f(p: Ptr<int32>, n: int32): int64 { const v: Span<int32> = p[1...n]; return v.length; }") == 0;
	assert strictErrorCount("struct Pet { a: uint64; }\nfunction f(p: Ptr<Pet>, n: uint32): uint64 { return p[0..n][0].a; }") == 0;
}

test "a read-only pointer slices into a read-only Span" {
	assert strictErrorCount("function f(p: Readonly<Ptr<uint8>>, n: uint64): int64 { const v: Readonly<Span<uint8>> = p[0..n]; return v.length; }") == 0;
	assert hasError("function f(p: Readonly<Ptr<uint8>>, n: uint64): void { const v: Span<uint8> = p[0..n]; }", "Type 'Readonly<Span<uint8>>' is not assignable to type 'Span<uint8>'");
	assert hasError("function f(p: Readonly<Ptr<uint8>>, n: uint64): void { p[0..n][0] = 1; }", "cannot write through Readonly<Span<uint8>>");
}

test "an untyped pointer, a tuple and a map cannot be sliced" {
	assert hasError("function f(p: Ptr<void>, n: uint64): int64 { return p[0..n].length; }", "cannot slice 'Ptr<void>' with '..'");
	assert hasError("const t: [int32, int32, int32] = [1, 2, 3];\nconst s = t[0..2];", NO_SLICE);
	assert hasError("const m = new Map<int32, int32>();\nconst s = m[0..2];", NO_SLICE);
}
