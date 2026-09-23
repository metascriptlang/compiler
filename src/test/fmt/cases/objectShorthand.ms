import { assertFmtLossless } from "../roundtrip";

test "fmt: an explicit key: value with the same name stays explicit" {
	assert assertFmtLossless("const conv = 1;\nconst w = { conv: conv, routine: conv };\n");
}

test "fmt: a shorthand property stays shorthand beside an explicit one" {
	assert assertFmtLossless("const name = \"n\";\nconst a = { name, other: name };\n");
}
