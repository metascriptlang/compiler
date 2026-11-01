import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

function holds(source: string): boolean {
	return assertFmtLossless(source) && assertFmtIdempotent(source);
}

test "fmt: a trailing array-pattern hole keeps its comma" {
	assert holds("const [p,,] = arr;\n");
	assert holds("let [q, ,] = z;\n");
	assert holds("const [, r, , s] = z;\n");
}

test "fmt: a comment between an object key and its colon stays there" {
	assert holds("const o = { a /* k */: 1 };\n");
	assert holds("const o = { \"b-c\" /* k */: 1, c: 2 };\n");
}

test "fmt: a block comment before a comma stays before it" {
	assert holds("import { a /* c */, b } from \"./m\";\n");
	assert holds("function f(a /* x */, b /* y */, c) {}\n");
}

test "fmt: a comment before ? or : stays before it" {
	assert holds("const t = c\n\t// why\n\t? 1\n\t: 2;\n");
	assert holds("const t = c\n\t? 1\n\t// else\n\t: 2;\n");
	assert holds("const t = c /* a */ ? 1 /* b */ : 2;\n");
}
