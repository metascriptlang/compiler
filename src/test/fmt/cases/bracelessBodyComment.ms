import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const inMatchArm = "function f(k: int32, sym: int32 | null): boolean {\n\tmatch (k) {\n\t\t1 => {\n\t\t\tif (sym == null) return false;\n\t\t\t// next check\n\t\t\treturn true;\n\t\t},\n\t\t_ => { return false; },\n\t}\n\treturn false;\n}\n";

test "fmt: a braceless if followed by a comment line stays braceless" {
	assert assertFmtLossless(inMatchArm);
}

test "fmt: a braceless if followed by a comment line is stable" {
	assert assertFmtIdempotent(inMatchArm);
}

test "fmt: a braceless if with a trailing comment stays braceless" {
	assert assertFmtLossless("function f(a: int32): void {\n\tfor (const x of [1]) {\n\t\tif (a == 0) continue; // skip\n\t\tg();\n\t}\n}\n");
}
