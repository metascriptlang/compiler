import { assertFmtLossless } from "../roundtrip";

test "fmt: a template with interpolations stays a template" {
	assert assertFmtLossless("function f(n: string, a: int32): string {\n\treturn `hello ${n}, age ${a}!`;\n}\n");
}

test "fmt: a template without interpolation stays a template" {
	assert assertFmtLossless("const s = `plain`;\n");
}

test "fmt: a template opening on an interpolation stays a template" {
	assert assertFmtLossless("function f(a: int32, b: int32): string {\n\treturn `${a}${b}`;\n}\n");
}

test "fmt: a template operand of * keeps no added parentheses" {
	assert assertFmtLossless("function f(a: string): string {\n\treturn g(`x${a}`.length * 2, `${a}` + a);\n}\n");
}

test "fmt: nested templates and braces inside an interpolation are copied whole" {
	assert assertFmtLossless("function f(a: string): string {\n\treturn `o ${a.length > 0 ? `in ${a}` : \"}\"} e`;\n}\n");
}
