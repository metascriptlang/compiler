import { assertFmtLossless } from "../roundtrip";

test "fmt: a comptime block prints as written" {
	assert assertFmtLossless("@comptime {\n\tconst names = [\"a\", \"}\"];\n\temit(names);\n}\nconst x = 1;\n");
}

test "fmt: a quote expression prints as written" {
	assert assertFmtLossless("macro m(v: Node): Node {\n\treturn quote { splice(v) + 1 };\n}\n");
}
