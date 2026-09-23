import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const grouped = "enum Op {\n\t// Memory (3)\n\tLoadConst,\n\tMove, // copy\n\t// Control\n\tJump,\n\t// end\n}\n";

test "fmt: standalone comments between enum members stay in place" {
	assert assertFmtLossless(grouped);
}

test "fmt: standalone comments between enum members are stable" {
	assert assertFmtIdempotent(grouped);
}
