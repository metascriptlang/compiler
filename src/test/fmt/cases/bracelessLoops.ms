import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

test "fmt: a braceless for body stays braceless" {
	assert assertFmtLossless("function f(n: int32): string {\n\tlet s = \"\";\n\tfor (let i = 0; i < n; i++) s = s + \" \";\n\treturn s;\n}\n");
}

test "fmt: braceless for-of and while bodies stay braceless" {
	assert assertFmtLossless("function f(xs: int32[]): int32 {\n\tlet t = 0;\n\tfor (const x of xs) t = t + x;\n\twhile (t > 10) t = t - 1;\n\treturn t;\n}\n");
}

test "fmt: a braceless else under a braced if stays braceless" {
	assert assertFmtLossless("function f(a: int32): int32 {\n\twhile (true) {\n\t\tif (a > 0) {\n\t\t\ta = a - 1;\n\t\t} else break;\n\t}\n\treturn a;\n}\n");
}

test "fmt: a braceless if after a multi-line condition stays braceless" {
	assert assertFmtLossless("function f(a: int32, b: int32): boolean {\n\tif (a == 0\n\t\t|| b == 0) return true;\n\treturn false;\n}\n");
}

test "fmt: a braceless for body is stable" {
	assert assertFmtIdempotent("function f(n: int32): int32 {\n\tlet t = 0;\n\tfor (let i = 0; i < n; i++) t = t + i;\n\treturn t;\n}\n");
}
