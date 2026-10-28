import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const fn = "extern function find(label: cstring): boolean from \"document.querySelector('[aria-label=\\\"' + # + '\\\"]')\";\n";
const value = "export extern const sep: string from \"a\\\\b \\\"c\\\"\";\n";

test "fmt: an extern function's native string keeps its escaped quotes" {
	assert assertFmtLossless(fn);
	assert assertFmtIdempotent(fn);
}

test "fmt: an exported extern value's native string keeps its escaped backslash and quotes" {
	assert assertFmtLossless(value);
	assert assertFmtIdempotent(value);
}
