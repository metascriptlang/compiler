import { assertFmtContains, assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

test "fmt: an empty loop body stays a semicolon" {
	const src = "let n = 0;\nwhile (n++ < 2);\nfor (n = 0; n < 3; n += 1);\n";
	assert assertFmtLossless(src);
	assert assertFmtIdempotent(src);
	assert assertFmtContains(src, "while (n++ < 2);");
	assert assertFmtContains(src, "for (n = 0; n < 3; n += 1);");
}

test "fmt: an empty do body and an empty else stay empty statements" {
	const src = "let n = 0;\ndo; while (++n < 2);\nif (n > 5) n = 1; else;\n";
	assert assertFmtLossless(src);
	assert assertFmtIdempotent(src);
	assert assertFmtContains(src, "do; while (++n < 2);");
}

test "fmt: a lone semicolon statement does not absorb the following block" {
	const src = "let n = 0;\n;\nwhile (n++ < 2);\n{\n\tn += 10;\n}\n";
	assert assertFmtLossless(src);
	assert assertFmtIdempotent(src);
}
