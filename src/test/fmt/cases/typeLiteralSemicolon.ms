import { assertFmtContains } from "../roundtrip";

test "fmt: a type literal prints no space before a semicolon" {
	assert assertFmtContains("type T = { a: number; b: string }\n", "{ a: number; b: string }");
}

test "fmt: a type literal one level deeper prints no space before a semicolon" {
	assert assertFmtContains("type T = { a: { b: number; c: string }; d: string }\n", "{ a: { b: number; c: string }; d: string }");
}
