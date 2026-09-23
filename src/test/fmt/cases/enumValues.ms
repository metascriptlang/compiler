import { assertFmtLossless } from "../roundtrip";

test "fmt: enum members keep their explicit values" {
	assert assertFmtLossless("enum Kind {\n\tNormal = 1000,\n\tHigh,\n\tAlias = 1, // bit 0\n}\n");
}

test "fmt: enum members keep hex and expression values" {
	assert assertFmtLossless("enum Bits {\n\tA = 0x10,\n\tB = (1 << 2),\n}\n");
}
