import { assertFmtLossless } from "../roundtrip";

test "fmt: a spread in an object literal stays a spread" {
	assert assertFmtLossless("const merged = { ...base, height: 20.0 };\n");
}

test "fmt: quoted keys keep their quotes" {
	assert assertFmtLossless("const lit = { \"one\": \"u1\", 'two': \"u2\", \"a-b\": 3 };\n");
}

test "fmt: a computed key keeps its expression" {
	assert assertFmtLossless("const m = { [k + \"]\"]: 1, [names[0]]: 2 };\n");
}
