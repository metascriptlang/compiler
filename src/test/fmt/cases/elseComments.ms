import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const chain = "function f(a: boolean, b: boolean): int32 {\n\tif (a) {\n\t\treturn 1;\n\t}\n\t// b wins next\n\telse if (b) {\n\t\treturn 2;\n\t}\n\t// otherwise\n\telse {\n\t\treturn 3;\n\t}\n}\n";

test "fmt: comments before else stay before it" {
	assert assertFmtLossless(chain);
}

test "fmt: comments before else are stable" {
	assert assertFmtIdempotent(chain);
}

test "fmt: a trailing comment on a braceless branch stays before the next else" {
	assert assertFmtLossless("function f(op: string, v: int32): int32 {\n\tif (op == \"*\") v = v * 2;\n\telse if (op == \"/\") v = v / 2; // integer division\n\telse if (op == \"%\") v = v % 2;\n\treturn v;\n}\n");
}
