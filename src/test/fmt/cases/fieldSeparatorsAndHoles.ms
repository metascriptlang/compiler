import { assertFmtLossless } from "../roundtrip";

test "fmt: comma-separated interface fields keep their commas" {
	assert assertFmtLossless("interface P { x: number, s: string }\n");
}

test "fmt: comma separators survive a generic type and a comment" {
	assert assertFmtLossless("interface Q {\n\tm: Map<string, int32>, // lookup\n\tn: int32;\n}\n");
}

test "fmt: holes in an array pattern stay holes" {
	assert assertFmtLossless("const [, , ...r2] = src;\nconst [a, , c] = src;\n");
}
