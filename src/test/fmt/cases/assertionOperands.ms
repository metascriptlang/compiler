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

test "fmt: a prefix or update operand of as gains no parentheses" {
	assert assertFmtLossless("const a = typeof x as string;\nconst b = ++i as int32;\nconst c = i++ as int32;\n");
}

test "fmt: an await operand of as gains no parentheses" {
	assert assertFmtLossless("const d = await p as int32;\n");
}

test "fmt: parentheses around an as under a prefix operator stay" {
	assert assertFmtLossless("const a = -(x as int8);\nconst b = typeof (x as T);\n");
	assert assertFmtPreservesAst("const a = -(x as int8) as int16;");
}
