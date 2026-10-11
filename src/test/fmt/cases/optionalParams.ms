// Optional parameters `x?: T` print as written in every position that parses them.
//
// Symptom:    fmt printed the desugared `x: (T) | null = null`, which the lossless check refuses.
// Root cause: buildParamList read the type text and the default node, neither of which remembers the `?`.
// Fix:        buildParamList asks the source whether the parameter was written with `?` (as the
//             field printer does) and then prints `name?: T` with no default.

import { assertFmtContains, assertFmtIdempotent, assertFmtLossless } from "../roundtrip";

const everyPosition = "function f(a: int32, xs?: number[], s?: string): void { }\n"
	+ "const g = (p?: string): string => \"\";\n"
	+ "const h = function (n?: int32): int32 { return 1; };\n"
	+ "class C {\n\tconstructor(n?: int32) { }\n\tm(c?: C, ...rest: int32[]): int32 { return 1; }\n}\n"
	+ "extern function cf(x?: int32): void from \"abs\";\n"
	+ "type F = (a: int32, b?: string) => void;\n"
	+ "function d({ a }?: { a: int32 }): void;\n"
	+ "function w<T>(x?: T | null, y?: (n: int32) => int32): void { }\n";

test "fmt: an optional parameter prints as written in every position" {
	assert assertFmtLossless(everyPosition);
	assert assertFmtIdempotent(everyPosition);
}

test "fmt: an optional parameter keeps its type and gets no default" {
	assert assertFmtContains("function f(xs?: number[]): void { }", "function f(xs?: number[]): void");
	assert assertFmtContains("const g = (p?: string): string => \"\";", "(p?: string)");
	assert assertFmtContains("class C { constructor(n?: int32) { } }", "constructor(n?: int32)");
}
