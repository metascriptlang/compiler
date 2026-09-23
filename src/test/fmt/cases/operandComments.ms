import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const chain = "const raw =\n\t\"HTTP/1.1 101\r\n\" +\n\t\"Accept: ABC \r\n\" +  // trailing space\n\t\"\r\n\";\n";

test "fmt: a comment after a binary operator stays before the right operand" {
	assert assertFmtLossless(chain);
}

test "fmt: a comment after a binary operator is stable" {
	assert assertFmtIdempotent(chain);
}

test "fmt: a comment after && stays before the right operand" {
	assert assertFmtLossless("const ok = a &&\n\t// b must hold too\n\tb;\n");
}
