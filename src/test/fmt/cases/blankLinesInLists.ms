import { assertFmtContains, assertFmtIdempotent, fmt } from "../roundtrip";

test "fmt: a block keeps one blank line where the source had one or more" {
	assert assertFmtContains("function f() {\n\tconst a = 1\n\n\tconst b = 2\n\n\n\n\treturn a + b\n}\n", "const a = 1;\n\n  const b = 2;\n\n  return a + b;");
	assert assertFmtContains("function f() {\n\tconst a = 1\n\tconst b = 2\n}\n", "const a = 1;\n  const b = 2;");
}

test "fmt: a class body keeps a blank line before a member and before its comment" {
	assert assertFmtContains("class C {\n\tx = 1\n\n\ty = 2\n\n\t// about m\n\tm() {}\n\tn() {}\n}\n", "x = 1;\n\n  y = 2;\n\n  // about m\n  m() {}\n  n() {}");
}

test "fmt: an enum keeps a blank line between members" {
	assert assertFmtContains("enum E {\n\tA,\n\n\tB,\n\tC,\n}\n", "A,\n\n  B,\n  C,");
}

test "fmt: an interface keeps a blank line before a field, a comment or a decorated field" {
	assert assertFmtContains("interface I {\n\ta: number\n\n\t// about b\n\tb: string\n\tc: string\n}\n", "a: number;\n\n  // about b\n  b: string;\n  c: string;");
	assert assertFmtContains("struct S {\n\ta: int32\n\n\t@packed\n\tb: int32\n}\n", "a: int32;\n\n  @packed\n  b: int32;");
}

test "fmt: a switch keeps a blank line between cases and between the statements of one case" {
	assert assertFmtContains("switch (x) {\n\tcase 1:\n\t\ta()\n\n\t\tb()\n\t\tbreak\n\n\tcase 2:\n\t\tbreak\n\tdefault:\n\t\tz()\n}\n", "a();\n\n    b();\n    break;\n\n  case 2:\n    break;\n  default:");
}

test "fmt: a blank line one level deeper survives and a second pass keeps it" {
	const source = "class C {\n\tm() {\n\t\tif (a) {\n\t\t\tb()\n\n\t\t\tc()\n\t\t}\n\n\t\td()\n\t}\n}\n";
	assert assertFmtContains(source, "b();\n\n      c();\n    }\n\n    d();");
	assert assertFmtIdempotent(source);
	assert fmt(source) == fmt(fmt(source));
}
