import { assertFmtContains, assertFmtPreservesAst, fmt } from "../roundtrip";

test "fmt: a braceless if on one line keeps no braces" {
	const source = "function f(x: int32): int32 {\n\tif (x == 0) return 1;\n\treturn x;\n}\n";
	assert assertFmtPreservesAst(source);
	assert assertFmtContains(source, "if (x == 0) return 1;");
	assert fmt(fmt(source)).contains("if (x == 0) return 1;");
}

test "fmt: a braceless if/else on one line keeps no braces" {
	const source = "function f(x: int32): int32 {\n\tif (x == 0) return 1; else return 2;\n}\n";
	assert assertFmtPreservesAst(source);
	assert assertFmtContains(source, "if (x == 0) return 1; else return 2;");
}

test "fmt: a braceless body on the next line gets braces" {
	const source = "function f(x: int32): int32 {\n\tif (x == 0)\n\t\treturn 1;\n\treturn x;\n}\n";
	assert assertFmtPreservesAst(source);
	assert assertFmtContains(source, "if (x == 0) { return 1; }");
}

test "fmt: a braced single-line if keeps its braces" {
	const source = "function f(x: int32): int32 {\n\tif (x == 0) { return 1; }\n\treturn x;\n}\n";
	assert assertFmtContains(source, "if (x == 0) { return 1; }");
}
