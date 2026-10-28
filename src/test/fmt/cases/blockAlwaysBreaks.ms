import { assertFmtPreservesAst, fmt } from "../roundtrip";

test "fmt: a one-statement if block breaks onto its own lines" {
	const source = "function f(x: number): number { if (x === 0) { return 1; } return x; }";
	assert assertFmtPreservesAst(source);
	assert fmt(source) == "function f(x: number): number {\n\tif (x === 0) {\n\t\treturn 1;\n\t}\n\treturn x;\n}\n";
}

test "fmt: loop, arrow and nested one-statement blocks break at every level" {
	assert fmt("for (const v of xs) { use(v); }\n") == "for (const v of xs) {\n\tuse(v);\n}\n";
	assert fmt("const g = () => { return 1; };\n") == "const g = () => {\n\treturn 1;\n};\n";
	assert fmt("while (a) { if (b) { c(); } }\n") == "while (a) {\n\tif (b) {\n\t\tc();\n\t}\n}\n";
}

test "fmt: an empty function, loop, arrow and catch-only block stays on one line" {
	assert fmt("function f() {}\n") == "function f() {}\n";
	assert fmt("for (const v of xs) {}\n") == "for (const v of xs) {}\n";
	assert fmt("const g = () => {};\n") == "const g = () => {};\n";
	assert fmt("try { a(); } catch (e) {}\n") == "try {\n\ta();\n} catch (e) {}\n";
	assert fmt("class A { m() {} }\n") == "class A {\n\tm() {}\n}\n";
}

test "fmt: an empty if, try, finally and bare block breaks to two lines" {
	assert fmt("if (a) {}\n") == "if (a) {\n}\n";
	assert fmt("try {} finally {}\n") == "try {\n} finally {\n}\n";
	assert fmt("try { a(); } catch (e) {} finally {}\n") == "try {\n\ta();\n} catch (e) {\n} finally {\n}\n";
	assert fmt("{}\n") == "{\n}\n";
}
