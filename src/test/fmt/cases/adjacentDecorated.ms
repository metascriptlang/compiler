import { assertFmtIdempotent, assertFmtLossless, fmt } from "../roundtrip";

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

test "fmt: inline struct field decorators that overflow break one per line on the first pass" {
	const long = "export struct CappedAccounts {\n\towner: Signer;\n\t@hasOne(owner) @constraint(vault.stamp == 7, ProgramError.userError(4)) vault: Owned<Capped>;\n}\n";
	const expected = "export struct CappedAccounts {\n  owner: Signer;\n  @hasOne(owner)\n  @constraint(vault.stamp == 7, ProgramError.userError(4))\n  vault: Owned<Capped>;\n}\n";
	assert fmt(long) === expected;
	assert fmt(expected) === expected;
	assert assertFmtIdempotent("struct S {\n\t@hasOne(owner, counted(3)) @constraint(safe.limit > 5, counted(5)) safe: Owned<Safe>;\n\t@a(1) b: int32;\n}\n");
}

test "fmt: a decorated class property with call arguments is stable" {
	assert assertFmtIdempotent("class K {\n\t@hasOne(owner) @constraint(vault.stamp == 7, ProgramError.userError(4444444)) vault: Owned<Capped> = 1;\n}\n");
}
