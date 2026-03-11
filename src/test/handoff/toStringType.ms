// toString() return type resolution tests
//
// Pattern: `const s = someNumber.toString();`
// The variable should be typed as string, not void*.

import { compileToC } from "../helpers";

test "number.toString() result typed as string" {
	const src = "function fmt(n: number): string {\n\tconst s = n.toString();\n\treturn s;\n}";
	const result = compileToC(src);
	assert result.ok;
	// Should NOT contain void* for the toString result
	assert !result.value.contains("void* s");
}

test "field.toString() result typed as string" {
	const src = "interface Err { line: number; }\nfunction fmt(e: Err): string {\n\tconst lineStr = e.line.toString();\n\treturn lineStr;\n}";
	const result = compileToC(src);
	assert result.ok;
	assert !result.value.contains("void* lineStr");
}

test "toString inside if-block preserves type" {
	const src = "interface Err { line: number; }\nfunction fmt(e: Err): string {\n\tconst srcLine = \"hello\";\n\tif (srcLine.length > 0) {\n\t\tconst lineNumStr = e.line.toString();\n\t\treturn lineNumStr;\n\t}\n\treturn \"\";\n}";
	const result = compileToC(src);
	assert result.ok;
	assert !result.value.contains("void* lineNumStr");
}

test "toString return type is msString not void*" {
	const src = "function test(n: number): string {\n\tconst lineNumStr = n.toString();\n\treturn lineNumStr;\n}";
	const result = compileToC(src);
	assert result.ok;
	// The variable should be declared as msString, not void*
	assert !result.value.contains("void* lineNumStr");
}
