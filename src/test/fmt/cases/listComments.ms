import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const arrayCase = "const bad: uint8[] = [\n\t0x82, 0x7F, // FIN | Binary\n\t0x15, 0x16,\n\t// inline tail\n\t0x17,\n];\n";

test "fmt: comments inside an array literal stay in place" {
	assert assertFmtLossless(arrayCase);
}

test "fmt: comments inside an array literal are stable" {
	assert assertFmtIdempotent(arrayCase);
}

test "fmt: comments between call arguments stay in place" {
	assert assertFmtLossless("const t = makeStruct(\n\tmakeMember(\"len\", 1),\n\tmakeMember(\"data\", 2), // flexible\n);\n");
}

test "fmt: an array of calls with trailing comments keeps them" {
	assert assertFmtLossless("const code = [\n\tabx(1, 0, 0), // R0 = 10\n\tabx(2, 1, 0), // R1 = 20\n];\n");
}

test "fmt: a leading comment on an object element stays outside the object" {
	assert assertFmtLossless("const xs = [\n\t// first\n\t{ a: 1 },\n\t{ b: 2 }, // second\n];\n");
}
