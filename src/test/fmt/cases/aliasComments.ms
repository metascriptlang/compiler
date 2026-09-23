import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const union = "export type DocData =\n\t| { text: string }        // Text\n\t// Literal variants\n\t| { lines: string[] };\n";

test "fmt: comments between union members of a type alias stay in place" {
	assert assertFmtLossless(union);
}

test "fmt: comments between union members of a type alias are stable" {
	assert assertFmtIdempotent(union);
}
