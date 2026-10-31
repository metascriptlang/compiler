// Each match arm sits on its own line, as switch cases do: a match that fit the width used to
// print its arms joined with nothing between them. A long or-pattern breaks after each `|`.

import { fmt, assertFmtIdempotent, assertFmtPreservesAst } from "../roundtrip";

const ARMS = "const b: int32 = 1;\nconst s = match (b) {\n\t0 => 10,\n\t1 => 20,\n\t_ => 30,\n};\n";
const NAMES = "const FIRST_VALUE_NAME: int32 = 1;\nconst SECOND_VALUE_NAME: int32 = 2;\nconst THIRD_VALUE_NAME: int32 = 3;\nconst FOURTH_VALUE_NAME: int32 = 4;\n";
const LONG_OR = NAMES + "function pick(value: int32): int32 {\n\tmatch (value) {\n\t\tFIRST_VALUE_NAME |\n\t\t\tSECOND_VALUE_NAME |\n\t\t\tTHIRD_VALUE_NAME |\n\t\t\tFOURTH_VALUE_NAME => {\n\t\t\treturn 1;\n\t\t},\n\t\t_ => {\n\t\t\treturn 0;\n\t\t},\n\t};\n}\n";

test "fmt: short expression arms keep one arm per line" {
	assert fmt(ARMS) == ARMS, fmt(ARMS);
	assert assertFmtIdempotent(ARMS);
}

test "fmt: arms written on one line are split one per line" {
	assert fmt("const b: int32 = 1;\nconst s = match (b) { 0 => 10, 1 => 20, _ => 30 };\n") == ARMS;
}

test "fmt: a blank line between arms is kept" {
	const spaced = "const b: int32 = 1;\nconst s = match (b) {\n\t0 => 10,\n\n\t_ => 30,\n};\n";
	assert fmt(spaced) == spaced, fmt(spaced);
}

test "fmt: a long or-pattern breaks after each bar and stays broken" {
	assert fmt(LONG_OR) == LONG_OR, fmt(LONG_OR);
	const joined = LONG_OR.replace("FIRST_VALUE_NAME |\n\t\t\tSECOND_VALUE_NAME |\n\t\t\tTHIRD_VALUE_NAME |\n\t\t\tFOURTH_VALUE_NAME", "FIRST_VALUE_NAME | SECOND_VALUE_NAME | THIRD_VALUE_NAME | FOURTH_VALUE_NAME");
	assert fmt(joined) == LONG_OR, fmt(joined);
	assert assertFmtPreservesAst(LONG_OR);
}

test "fmt: a short or-pattern stays on one line" {
	const short = "const b: int32 = 1;\nconst s = match (b) {\n\t0 | 1 => 10,\n\t_ => 30,\n};\n";
	assert fmt(short) == short, fmt(short);
}
