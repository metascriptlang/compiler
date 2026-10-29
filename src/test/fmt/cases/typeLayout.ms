import { fmt, assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const union4 = "\"aaaaaaaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccccccc\" | \"ddddddddddddddddddd\"";
const bars = "\t| \"aaaaaaaaaaaaaaaaaaaa\"\n\t| \"bbbbbbbbbbbbbbbbbbbbbbb\"\n\t| \"cccccccccccccccccccccc\"\n\t| \"ddddddddddddddddddd\"";

test "fmt: a long union breaks with a leading bar after an alias, a return type and a parameter" {
	assert fmt("type A = " + union4 + ";\n") == "type A =\n" + bars + ";\n";
	assert fmt("function g(): " + union4 + " {}\n") == "function g():\n" + bars + " {}\n";
	assert fmt("function f(a: " + union4 + "): void {}\n") == "function f(\n\ta:\n\t\t| \"aaaaaaaaaaaaaaaaaaaa\"\n\t\t| \"bbbbbbbbbbbbbbbbbbbbbbb\"\n\t\t| \"cccccccccccccccccccccc\"\n\t\t| \"ddddddddddddddddddd\",\n): void {}\n";
}

test "fmt: a long union in a field or a type argument breaks without double indentation" {
	assert fmt("class C { x: " + union4 + " = 1; }\n") == "class C {\n\tx:\n\t\t| \"aaaaaaaaaaaaaaaaaaaa\"\n\t\t| \"bbbbbbbbbbbbbbbbbbbbbbb\"\n\t\t| \"cccccccccccccccccccccc\"\n\t\t| \"ddddddddddddddddddd\" = 1;\n}\n";
	assert fmt("let v: Map<string, " + union4 + ">;\n") == "let v: Map<\n\tstring,\n\t| \"aaaaaaaaaaaaaaaaaaaa\"\n\t| \"bbbbbbbbbbbbbbbbbbbbbbb\"\n\t| \"cccccccccccccccccccccc\"\n\t| \"ddddddddddddddddddd\"\n>;\n";
}

test "fmt: an object type breaks one member per line and ends its members with semicolons" {
	assert fmt("type O = { a: number, b: { c: string; d: number[] }, eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee: string, ffffffffffffffffffff: boolean };\n") == "type O = {\n\ta: number;\n\tb: { c: string; d: number[] };\n\teeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee: string;\n\tffffffffffffffffffff: boolean;\n};\n";
	assert fmt("type S = { a: number };\n") == "type S = { a: number };\n";
	assert fmt("type S2 = {\n  a: number };\n") == "type S2 = {\n\ta: number;\n};\n";
}

test "fmt: an intersection, a function type and a generic argument break by the reference's layout" {
	assert fmt("type I = Aaaaaaaaaaaaaaaaaaaaaaaaaaaa & Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb & Cccccccccccccccccccccccccccc & Dddddddddd;\n") == "type I = Aaaaaaaaaaaaaaaaaaaaaaaaaaaa &\n\tBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &\n\tCccccccccccccccccccccccccccc &\n\tDddddddddd;\n";
	assert fmt("type F = (aaaaaaaaaaaaaaaaaaa: string, bbbbbbbbbbbbbbbbbbbbbbbbb: number, ccccccccccccccccccc: boolean) => void;\n") == "type F = (\n\taaaaaaaaaaaaaaaaaaa: string,\n\tbbbbbbbbbbbbbbbbbbbbbbbbb: number,\n\tccccccccccccccccccc: boolean,\n) => void;\n";
	assert fmt("type G = Array<{ aaaaaaaaaaaaaaaaaaaaaaaaaaa: string, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: number, cccccccccccccccccc: boolean }>;\n") == "type G = Array<{\n\taaaaaaaaaaaaaaaaaaaaaaaaaaa: string;\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: number;\n\tcccccccccccccccccc: boolean;\n}>;\n";
}

test "fmt: a sole object-typed parameter hugs the parentheses" {
	assert fmt("function a(x: { aaaaaaaaaaaaaaaaaaaaaaaaaa: string; bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: number; cccccccccccccccc: boolean }) {}\n") == "function a(x: {\n\taaaaaaaaaaaaaaaaaaaaaaaaaa: string;\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: number;\n\tcccccccccccccccc: boolean;\n}) {}\n";
}

test "fmt: a union keeps parentheses around a function and under an array, and hugs a nullable reference" {
	assert fmt("type T1 = (A | B)[];\ntype T2 = (() => void) | null;\ntype T5 = Foo.Bar<string>[];\n") == "type T1 = (A | B)[];\ntype T2 = (() => void) | null;\ntype T5 = Foo.Bar<string>[];\n";
	assert fmt("function b(x: Foo | null, y: Bar<Baz> | null | void) {}\n") == "function b(x: Foo | null, y: Bar<Baz> | null | void) {}\n";
}

test "fmt: a type the tree does not carry keeps its written tokens" {
	assert fmt("type K = keyof Foo;\ntype Q = typeof foo;\ntype T = [number, string];\ntype X = Foo[\"a\"];\n") == "type K = keyof Foo;\ntype Q = typeof foo;\ntype T = [number, string];\ntype X = Foo[\"a\"];\n";
	assert assertFmtLossless("function f(a: keyof Foo | null, c: [A, B], b?: { x: number }): typeof z {}\n");
	assert assertFmtIdempotent("function f(a: keyof Foo | null, c: [A, B], b?: { x: number }): typeof z {}\n");
}
