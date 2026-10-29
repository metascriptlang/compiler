import { fmt } from "../roundtrip";

test "fmt: parentheses the reference leaves out when they bind nothing" {
	assert fmt("const a = a < b ? -1 : (a > b ? 1 : 0);\n") == "const a = a < b ? -1 : a > b ? 1 : 0;\n";
	assert fmt("const d = (a + b) + c;\n") == "const d = a + b + c;\n";
	assert fmt("const e = a + (b * c);\n") == "const e = a + b * c;\n";
	assert fmt("const j = (a && b) && c;\n") == "const j = a && b && c;\n";
	assert fmt("const n = f((a));\n") == "const n = f(a);\n";
	assert fmt("const o = !(a);\n") == "const o = !a;\n";
	assert fmt("const q = (a.b).c;\n") == "const q = a.b.c;\n";
}

test "fmt: parentheses the reference puts around a mixed operator pair" {
	assert fmt("const c = a && b || c && d;\n") == "const c = (a && b) || (c && d);\n";
	assert fmt("const f = a * b % c;\n") == "const f = (a * b) % c;\n";
	assert fmt("const g = a == b == c;\n") == "const g = (a == b) == c;\n";
	assert fmt("const h = a ** b ** c;\n") == "const h = a ** (b ** c);\n";
	assert fmt("const s = a & b | c;\n") == "const s = (a & b) | c;\n";
	assert fmt("const t = a << b + c;\n") == "const t = a << (b + c);\n";
}

test "fmt: parentheses around call arguments, array elements and returned values bind nothing" {
	assert fmt("const u = f((a + b), [(c + d)]);\n") == "const u = f(a + b, [c + d]);\n";
	assert fmt("function r() { return (a + b); }\n") == "function r() {\n\treturn a + b;\n}\n";
}

test "fmt: parentheses the reference keeps or adds around a mixed pair" {
	assert fmt("const v = (a ?? b) ? c : d;\n") == "const v = (a ?? b) ? c : d;\n";
	assert fmt("const w = a % 4 + 4;\n") == "const w = (a % 4) + 4;\n";
	assert fmt("const x = a + (b + c);\n") == "const x = a + (b + c);\n";
	assert fmt("const y = (a || b) && c;\n") == "const y = (a || b) && c;\n";
	assert fmt("const z = (a && b) || c;\n") == "const z = (a && b) || c;\n";
}
