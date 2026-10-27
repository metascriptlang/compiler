import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

function nested(body: string): string {
	return "class C {\n\tm(): void {\n\t\tif (ok) {\n" + body + "\n\t\t}\n\t}\n}\n";
}

function holds(source: string): boolean {
	return assertFmtLossless(source) && assertFmtIdempotent(source) && assertFmtLossless(nested(source)) && assertFmtIdempotent(nested(source));
}

test "fmt: an own-line comment ending an object stays inside it" {
	assert holds("const o = {\n\ta: 1,\n\t// last\n};");
}

test "fmt: an own-line comment ending an argument list stays inside it" {
	assert holds("f(1,\n\t// end\n);");
	assert holds("f(\n\t// only\n);");
}

test "fmt: a comment inside empty arguments stays inside them" {
	assert holds("f(/* c */);");
}

test "fmt: an own-line comment ending an array stays inside it" {
	assert holds("const a = [\n\t1,\n\t// end\n];");
}

test "fmt: an own-line comment before an object property stays before its key" {
	assert holds("const o = {\n\ta: 1,\n\t// own\n\tb: 2,\n};");
}

test "fmt: a comment after the last statement of a case stays in the switch" {
	assert holds("switch (x) {\n\tcase 1:\n\t\t// one\n\t\tbreak;\n\t\t// tail\n}");
}

test "fmt: a comment in an empty class or enum body stays inside it" {
	assert assertFmtLossless("class D { /* e */ }\nenum Z { /* e */ }\n");
	assert assertFmtIdempotent("class D { /* e */ }\nenum Z { /* e */ }\n");
}
