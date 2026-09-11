import { fmt, assertFmtContains } from "../roundtrip";

function before(out: string, first: string, second: string): boolean {
	const a = out.indexOf(first);
	const b = out.indexOf(second);
	if (a < 0 || b < 0 || a >= b) {
		console.log("FMT ORDER: expected '" + first + "' before '" + second + "'");
		console.log("formatted: " + out);
		return false;
	}
	return true;
}

test "fmt: a header comment block stays ahead of the first class" {
	const src = "// header one\n// header two\n\nclass A {\n\tf(): int32 { return 1; }\n}\n";
	assert assertFmtContains(src, "// header one\n// header two\n");
	assert before(fmt(src), "// header two", "class A");
}

test "fmt: a header comment block stays ahead of the first function" {
	const src = "// doc\nfunction g(): int32 {\n\treturn 1;\n}\n";
	assert before(fmt(src), "// doc", "function g");
}

test "fmt: a comment inside a body stays inside it" {
	const src = "function g(): int32 {\n\t// inner\n\treturn 1;\n}\n";
	const out = fmt(src);
	assert before(out, "function g", "// inner");
	assert before(out, "// inner", "return 1;");
}

test "fmt: a comment ahead of a method stays ahead of it" {
	const src = "class A {\n\t// about f\n\tf(): int32 { return 1; }\n}\n";
	const out = fmt(src);
	assert before(out, "class A", "// about f");
	assert before(out, "// about f", "f(): int32");
}

test "fmt: a comment between two statements keeps its place" {
	const src = "const a = 1;\n// about b\nconst b = 2;\n";
	const out = fmt(src);
	assert before(out, "const a = 1;", "// about b");
	assert before(out, "// about b", "const b = 2;");
}
