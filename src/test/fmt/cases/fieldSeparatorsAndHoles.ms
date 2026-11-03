import { assertFmtLossless, fmt } from "../roundtrip";

const COMMA_INTERFACE = "interface P { x: number, s: string }\n";
const COMMA_STRUCT = "struct S { a: int32, b: int32 }\n";
const COMMA_BEFORE_COMMENT = "interface Q {\n\tm: Map<string, int32>, // lookup\n\tn: int32;\n}\n";

test "fmt: comma-separated interface and struct fields print semicolons, as a type literal's members do" {
	assert fmt(COMMA_INTERFACE) == "interface P {\n\tx: number;\n\ts: string;\n}\n", fmt(COMMA_INTERFACE);
	assert fmt(COMMA_STRUCT) == "struct S {\n\ta: int32;\n\tb: int32;\n}\n", fmt(COMMA_STRUCT);
	assert assertFmtLossless(COMMA_INTERFACE);
	assert assertFmtLossless(COMMA_STRUCT);
}

test "fmt: a comma after a generic type and before a comment prints a semicolon" {
	assert fmt(COMMA_BEFORE_COMMENT) == "interface Q {\n\tm: Map<string, int32>; // lookup\n\tn: int32;\n}\n", fmt(COMMA_BEFORE_COMMENT);
	assert assertFmtLossless(COMMA_BEFORE_COMMENT);
}

test "fmt: holes in an array pattern stay holes" {
	assert assertFmtLossless("const [, , ...r2] = src;\nconst [a, , c] = src;\n");
}
