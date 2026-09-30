import { assertFmtIdempotent } from "../roundtrip";

test "fmt: one-line decorated declarations in a row format the same twice" {
	assert assertFmtIdempotent("type Signer = distinct Account;\n@delegate function key(this s: Signer): uint64;\n@delegate function bump(this ref s: Signer, by: uint64): void;\n@delegate type Payer = distinct Account;\n");
}

test "fmt: a multi-line decorated class keeps its separation from the next declaration" {
	assert assertFmtIdempotent("@withExtra\nclass A {\n\tn: int32 = 0;\n}\n@withExtra\nclass B {}\n");
}
