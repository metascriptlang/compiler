// sizeof folds at compile time; a type with no computable layout is refused.

import { compileToC } from "../helpers";

test "sizeof folds a primitive to its width" {
	const result = compileToC("const w: int32 = sizeof(int32);\nconsole.log(w);");
	assert result.ok;
	assert result.value.contains("= (int32_t)4;");
}

test "sizeof folds a struct to its padded width" {
	const result = compileToC("struct Mixed { a: char; b: int32 }\nconst w: int32 = sizeof(Mixed);\nconsole.log(w);");
	assert result.ok;
	assert result.value.contains("= (int32_t)8;");
}

test "sizeof refuses a type with no computable layout" {
	const result = compileToC("extern class OpaqueThing;\nconst w: int32 = sizeof(OpaqueThing);\nconsole.log(w);");
	assert !result.ok;
	assert result.error.contains("'sizeof' needs a type with a known layout");
}

test "sizeof refuses void rather than folding it to zero" {
	const result = compileToC("const w: int32 = sizeof(void);\nconsole.log(w);");
	assert !result.ok;
	assert result.error.contains("'sizeof' needs a type with a known layout");
}
