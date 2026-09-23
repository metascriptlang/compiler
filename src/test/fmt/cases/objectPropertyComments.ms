import { assertFmtLossless } from "../roundtrip";

test "fmt: a comment before a property whose value holds a call stays before the property" {
	assert assertFmtLossless("const n = createNode(k, {\n\ta: 1,\n\t// prefer nameLoc\n\tnameLocation: nameLoc != null ? nameLoc : makeLoc(token),\n}, t);\n");
}

test "fmt: a comment before a spread property stays before it" {
	assert assertFmtLossless("const m = {\n\ta: 1,\n\t// defaults last\n\t...base,\n};\n");
}
