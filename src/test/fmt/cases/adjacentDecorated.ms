import { assertFmtIdempotent } from "../roundtrip";

test "fmt: one-line decorated declarations in a row format the same twice" {
	assert assertFmtIdempotent("type Signer = distinct Account;\n@borrow function key(this s: Signer): uint64;\n@borrow function bump(this ref s: Signer, by: uint64): void;\n@borrow type Payer = distinct Account;\n");
}

test "fmt: a multi-line decorated class keeps its separation from the next declaration" {
	assert assertFmtIdempotent("@withExtra\nclass A {\n\tn: int32 = 0;\n}\n@withExtra\nclass B {}\n");
}
