// A macro whose first parameter is `this src: Node` prints back as written.

import { assertFmtPreservesAst, assertFmtContains } from "../roundtrip";

test "fmt: a macro receiver parameter keeps its this" {
	const src = "macro whereM(this src: Node, fn: Node): Node { return src; }";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "macro whereM(this src: Node, fn: Node): Node");
}

test "fmt: a macro without a receiver is unchanged" {
	const src = "macro whereM(src: Node): Node { return src; }";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "macro whereM(src: Node): Node");
}
