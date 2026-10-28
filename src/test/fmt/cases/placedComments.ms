import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

function nested(body: string): string {
	return "class C {\n\tm(): void {\n\t\tif (ok) {\n" + body + "\n\t\t}\n\t}\n}\n";
}

function holds(source: string): boolean {
	return assertFmtLossless(source) && assertFmtIdempotent(source) && assertFmtLossless(nested(source)) && assertFmtIdempotent(nested(source));
}

test "fmt: an inline block comment before an operand stays before it" {
	assert holds("foo(a, /* c */ b);");
	assert holds("const x = /* c */ 1;");
	assert holds("const y = a + /* c */ b;");
	assert holds("const z = t ? /* c */ 1 : 2;");
	assert holds("const arr = [1, /* c */ 2];");
}

test "fmt: an inline block comment after an operand stays after it" {
	assert holds("foo(a /* c */, b);");
	assert holds("if (/* c */ a) { b(); }");
}

test "fmt: a comment before an object value stays after the key" {
	assert holds("const o = { a: /* c */ 1 };");
}

test "fmt: a comment before a returned value stays before it" {
	assert holds("function f() { return /* c */ 1; }");
}

test "fmt: a comment before a ternary question mark stays there" {
	assert holds("const v = cond // test\n\t? 1\n\t: 2;");
}

test "fmt: a comment between chained members stays on its own line" {
	assert holds("foo(a)\n\t// c\n\t.bar();");
}
