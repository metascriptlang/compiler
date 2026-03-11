// Match expression result variable DRC tests
//
// Pattern: match lowering creates `let $matchres = undefined` as placeholder.
// DRC must not generate lifecycle calls with empty function names for this.

import { compileToC } from "../helpers";

test "match result with Result type no empty_ call" {
	const src = "enum Color { Red, Blue }\nfunction pick(c: Color): string {\n\treturn match (c) {\n\t\tColor.Red => \"red\",\n\t\tColor.Blue => \"blue\",\n\t\t_ => \"unknown\",\n\t};\n}";
	const result = compileToC(src);
	assert result.ok;
	// Should NOT contain empty_ function call (from mangle(""))
	assert !result.value.contains("empty_");
}

test "match result variable properly initialized" {
	const src = "function test(x: number): string {\n\treturn match (x) {\n\t\t1 => \"one\",\n\t\t2 => \"two\",\n\t\t_ => \"other\",\n\t};\n}";
	const result = compileToC(src);
	assert result.ok;
	assert !result.value.contains("empty_");
}
