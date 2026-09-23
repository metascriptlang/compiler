import { assertFmtLossless } from "../roundtrip";

test "fmt: an array pattern rest prints one spread" {
	assert assertFmtLossless("const [a, b, ...rest] = src;\n");
}

test "fmt: an object pattern rest prints one spread" {
	assert assertFmtLossless("const { id, ...more } = row;\n");
}
