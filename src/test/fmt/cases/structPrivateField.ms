import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

test "fmt: a struct keeps a private field's modifier" {
	const source = "struct Signer { private account: Account; owner: uint64; }";
	assert assertFmtLossless(source);
	assert assertFmtPreservesAst(source);
}

test "fmt: a private field after a nullable one keeps its trailing comment" {
	const source = "struct Proof {\n\tnote: string | null;\n\tprivate key: uint64; // the key\n}";
	assert assertFmtLossless(source);
	assert assertFmtPreservesAst(source);
}
