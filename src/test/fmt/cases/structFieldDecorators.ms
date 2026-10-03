// Decorators on struct and interface fields survive fmt: same AST shape, no lost token,
// the written layout (same line or own line) is kept, and a second pass changes nothing.

import { assertFmtContains, assertFmtIdempotent, assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

test "fmt: struct field decorators with arguments stay on the field's line" {
	const src = "struct A {\n\t@signer @seeds(\"config\", mint) maker: int32;\n\t@bump(config.bump) bump: int32;\n\tplain: int32;\n}";
	assert assertFmtPreservesAst(src);
	assert assertFmtLossless(src);
	assert assertFmtIdempotent(src);
	assert assertFmtContains(src, "@signer @seeds(\"config\", mint) maker: int32;");
	assert assertFmtContains(src, "@bump(config.bump) bump: int32;");
}

test "fmt: struct field decorators written on their own line stay on their own line" {
	const src = "struct A {\n\t@signer\n\t@address(Pubkey.systemProgram())\n\tvault: int32;\n}";
	assert assertFmtPreservesAst(src);
	assert assertFmtLossless(src);
	assert assertFmtIdempotent(src);
	assert assertFmtContains(src, "@signer\n  @address(Pubkey.systemProgram())\n  vault: int32;");
}

test "fmt: interface field decorators and a trailing comment on a decorated field survive" {
	const src = "interface I {\n\t@label(\"x\") note: string; // keep\n\tplain: string;\n}";
	assert assertFmtPreservesAst(src);
	assert assertFmtLossless(src);
	assert assertFmtContains(src, "@label(\"x\") note: string; // keep");
}
