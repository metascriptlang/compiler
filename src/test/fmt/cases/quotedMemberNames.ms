// A quoted member name keeps its quotes through the formatter, in every declaration position.

import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: quoted member names keep their quotes" {
	const src = "interface P {\n\t\"data-id\": string;\n\t\"aria-label\"?: string;\n}\ntype T = { \"x-y\": number };\nclass C {\n\t\"data-probe\": string = \"p\";\n}";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "\"data-id\": string;");
	assert assertFmtContains(src, "\"aria-label\"?: string;");
	assert assertFmtContains(src, "\"x-y\": number");
	assert assertFmtContains(src, "\"data-probe\": string = \"p\";");
}
