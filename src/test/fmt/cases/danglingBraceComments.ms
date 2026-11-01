import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

function holds(source: string): boolean {
	return assertFmtLossless(source) && assertFmtIdempotent(source);
}

test "fmt: a comment inside an empty object literal stays inside it" {
	assert holds("const x = {\n\t// c\n};\n");
	assert holds("const x = { /* c */ };\n");
	assert holds("f({ // c\n});\n");
}

test "fmt: a comment inside an empty object pattern stays inside it" {
	assert holds("const { /* c */ } = v;\n");
	assert holds("function g({ // c\n}) {}\n");
}
