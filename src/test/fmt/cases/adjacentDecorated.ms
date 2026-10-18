import { assertFmtIdempotent, assertFmtLossless } from "../roundtrip";

test "fmt: one-line decorated declarations in a row format the same twice" {
	assert assertFmtIdempotent("type Signer = distinct Account;\n@delegate function key(this s: Signer): uint64;\n@delegate function bump(this ref s: Signer, by: uint64): void;\n@delegate type Payer = distinct Account;\n");
}

test "fmt: a multi-line decorated class keeps its separation from the next declaration" {
	assert assertFmtIdempotent("@withExtra\nclass A {\n\tn: int32 = 0;\n}\n@withExtra\nclass B {}\n");
}

test "fmt: a comment after a decorated declaration stays between the two declarations" {
	assert assertFmtLossless("@builtin(\"I\")\nexport struct It {\n\tn: int32;\n}\n\n// c\nexport function f(): void {}\n");
	assert assertFmtLossless("@inline\nfunction g(): void {}\n\n// d\nfunction h(): void {}\n");
}
