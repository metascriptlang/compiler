import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

function keeps(src: string): boolean {
	return assertFmtLossless(src) && assertFmtIdempotent(src);
}

test "fmt: a comment inside a variable's type stays there, with a literal or a binary initializer" {
	assert keeps("let v: /* c */ int32 = 1;\n");
	assert keeps("let a = 1;\nlet b = 2;\nlet v: /* c */ int32 = a + b;\n");
	assert keeps("let p: /* c */ int32, q: int32 = 2;\n");
}

test "fmt: a comment inside an arrow's return type stays there, for an expression and a block body" {
	assert keeps("const g = (x: int32): /* c */ int32 => x;\n");
	assert keeps("const g = (x: int32): /* c */ int32 => x + 1;\n");
	assert keeps("const g = async (x: int32): /* c */ Promise<int32> => x;\n");
	assert keeps("const g = (x: int32): /* c */ int32 => { return x; };\n");
}
