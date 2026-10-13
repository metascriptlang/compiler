// Checker — `x[a..b]` slices only a source whose length bounds the slice

import { strictErrorCount, hasError } from "./helpers";

const NO_SLICE = "only an array, a Span or a string has the length that bounds a slice";

test "an array, a sized array, a Span and a string slice" {
	assert strictErrorCount("function f(a: int32[]): int64 { return a[0..2].length; }") == 0;
	assert strictErrorCount("function f(): int64 { const a: int32[4] = [1, 2, 3, 4]; return a[1...3].length; }") == 0;
	assert strictErrorCount("function f(xs: Span<int32>): int64 { return xs[1..2].length; }") == 0;
	assert strictErrorCount("function f(s: string): int64 { return s[0..3].length; }") == 0;
	assert strictErrorCount("function f<T>(xs: T): int64 { return xs[0..2].length; }") == 0;
}

test "a pointer, a tuple and a map have no length to bound a slice" {
	assert hasError("struct Pet { a: uint64; }\nlet arr: Pet[4] = [];\nconst q = arr as Ptr<Pet>;\nconst s = q[0..3];", "cannot slice 'Ptr<Pet>' with '..'");
	assert hasError("let arr: uint8[4] = [1, 2, 3, 4];\nconst q = arr as Ptr<uint8>;\nconst s = q[0...2];", "cannot slice 'Ptr<uint8>' with '...'");
	assert hasError("const t: [int32, int32, int32] = [1, 2, 3];\nconst s = t[0..2];", NO_SLICE);
	assert hasError("const m = new Map<int32, int32>();\nconst s = m[0..2];", NO_SLICE);
}
