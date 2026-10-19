import { checkOnly } from "../helpers";

const PRELUDE = "function noop(): void { }\n"
	+ "function fail(): never { throw new Error(\"x\"); }\n"
	+ "class K { m(): void { } }\n";

const VOID_TEXT = "a 'void' value has no text — a void call produces no value; call it on its own line";

function errorsOf(body: string): string {
	return checkOnly(PRELUDE + body).errors.join("\n");
}

test "a void call in a template is refused" {
	const text = errorsOf("const s = `v=${noop()}`;\n");
	assert text.contains(VOID_TEXT), "a template over a void call must fail the checker: " + text;
}

test "String() of a void call is refused" {
	const text = errorsOf("const s = String(noop());\n");
	assert text.contains(VOID_TEXT), "String(noop()) must fail the checker: " + text;
}

test "concatenating a void call on either side is refused" {
	assert errorsOf("const s = \"\" + noop();\n").contains(VOID_TEXT), "\"\" + noop() must fail the checker";
	assert errorsOf("const s = noop() + \"\";\n").contains(VOID_TEXT), "noop() + \"\" must fail the checker";
	assert errorsOf("let s = \"a\";\ns += noop();\n").contains(VOID_TEXT), "s += noop() must fail the checker";
}

test "a void method call in a template is refused" {
	const text = errorsOf("const k = new K();\nconst s = `m=${k.m()}`;\n");
	assert text.contains(VOID_TEXT), "a template over a void method call must fail the checker: " + text;
}

test "a never value in a template, String() or concatenation checks, since it raises before any text is made" {
	for (const body of ["function t(): string { return `x=${fail()}`; }\n", "function t(): string { return String(fail()); }\n",
		"function t(): string { return \"y\" + fail(); }\n", "function t(x: never): string { return \"Unexpected: \" + x; }\n"]) {
		const text = errorsOf(body);
		assert text == "", "text over never must check: " + text;
	}
}

test "a void call on its own line and text of values still check" {
	const result = checkOnly(PRELUDE + "noop();\nconst n: int32 = 1;\nconst s = `n=${n}` + String(n) + \"!\";\n");
	assert result.errors.length == 0, "plain text must check: " + result.errors.join("\n");
}
