import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

test "fmt: a chained as keeps no added parentheses" {
	assert assertFmtLossless("const n = null as unknown as Node;\n");
}

test "fmt: a three-step as chain on a member keeps no added parentheses" {
	assert assertFmtLossless("const h = w.root as unknown as Ptr<void> as HostNode;\n");
}

test "fmt: a binary operand of as keeps its parentheses" {
	assert assertFmtPreservesAst("const a: int32 = 1; const b: int32 = 2; const c = (a + b) as int64;");
}
