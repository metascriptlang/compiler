import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const matchComments = "function f(k: int32): int32 {\n\treturn match (k) {\n\t\t// first\n\t\t1 => 10,\n\t\t// second\n\t\t2 => 20,\n\t\t_ => 0, // trailing\n\t};\n}\n";

test "fmt: comments between match arms stay between them" {
	assert assertFmtLossless(matchComments);
}

test "fmt: comments between match arms are stable" {
	assert assertFmtIdempotent(matchComments);
}

test "fmt: a comment in an empty block stays inside it" {
	assert assertFmtLossless("function f(k: int32): void {\n\tif (k > 0) {\n\t\t// nothing yet\n\t}\n\tg();\n}\n");
}

test "fmt: a comment after the last statement of a block stays inside it" {
	assert assertFmtLossless("function f(): void {\n\tg();\n\t// done\n}\nfunction h(): void {}\n");
}

test "fmt: a comment in an empty match arm block stays inside it" {
	assert assertFmtLossless("function f(k: int32): void {\n\tmatch (k) {\n\t\t1 => {\n\t\t\t// ignored\n\t\t},\n\t\t_ => { g(); },\n\t};\n}\n");
}
