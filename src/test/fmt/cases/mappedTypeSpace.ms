import { assertFmtContains } from "../roundtrip";

test "fmt: a readonly mapped type keeps the space before its bracket" {
	assert assertFmtContains("type M = { readonly [K in keyof T]: T[K] }\n", "{ readonly [K in keyof T]: T[K] }");
}

test "fmt: a readonly tuple keeps the space before its bracket" {
	assert assertFmtContains("type A = readonly [string, number]\n", "readonly [string, number]");
}
