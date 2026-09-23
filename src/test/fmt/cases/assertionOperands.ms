import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

test "fmt: an as chain on the right of == gains no parentheses" {
	assert assertFmtLossless("function f(cond: Node | null): boolean {\n\treturn cond == null as unknown as Node;\n}\n");
}

test "fmt: a negative literal cast gains no parentheses" {
	assert assertFmtLossless("const a = -1 as int32;\nconst b = !x as boolean;\n");
}

test "fmt: a unary inside another unary gains no parentheses" {
	assert assertFmtLossless("const a = ~-5n;\nconst b = !!x;\n");
}

test "fmt: minus over minus keeps what the source wrote" {
	assert assertFmtPreservesAst("const x: int32 = 1; const a = -(-x);");
}
