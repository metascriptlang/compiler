import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

test "fmt: a constructor keeps its private or protected modifier" {
	const source = "class Token {\n\tprivate constructor() {}\n\tstatic make(): Token { return new Token(); }\n}\nclass Shape {\n\tprotected constructor(n: int32) {}\n}";
	assert assertFmtLossless(source);
	assert assertFmtPreservesAst(source);
}
