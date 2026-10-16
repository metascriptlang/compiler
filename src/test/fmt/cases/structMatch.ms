// A discriminated union declared `struct X = match` keeps its keyword: printing it as `type`
// would turn a value union into a shared one.

import { fmt, assertFmtPreservesAst } from "../roundtrip";

const decl = "enum K { A, B }\nstruct Body<T, E> = match (k: K) { K.A => { value: T }, K.B => { error: E } };\n";

test "fmt: a struct match keeps its keyword" {
	assert fmt(decl).indexOf("struct Body<T, E> = match (k: K) {") >= 0;
	assert fmt(decl.replace("struct", "type")).indexOf("type Body<T, E> = match (k: K) {") >= 0;
}

test "fmt: a struct match preserves its AST" {
	assert assertFmtPreservesAst(decl);
	assert assertFmtPreservesAst("export " + decl.replace("enum K { A, B }\n", "enum K { A, B }\nexport "));
}
