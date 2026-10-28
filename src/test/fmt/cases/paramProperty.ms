import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: a constructor parameter property keeps its modifiers" {
	const src = "class K {\n\tconstructor(public a: int32, private readonly b: int32) {}\n}\n";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "constructor(public a: int32, private readonly b: int32) {}");
}

test "fmt: protected, bare readonly and an optional parameter property" {
	const src = "class K {\n\tconstructor(protected c: int32, readonly d: int32, public e?: string) {}\n}\n";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "constructor(protected c: int32, readonly d: int32, public e?: string) {}");
}

test "fmt: a derived class keeps its parameter properties beside super" {
	const src = "class D extends B {\n\tconstructor(p: int32, public q: int32 = 2) {\n\t\tsuper(p);\n\t}\n}\n";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "constructor(p: int32, public q: int32 = 2) {");
}
