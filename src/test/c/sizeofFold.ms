// sizeof folds at compile time; a type with no computable layout defers to the C compiler.

import { compileToC } from "../helpers";
import { TargetInfo } from "../../checker/types";

const avr: TargetInfo = { ptrSize: 2, floatSize: 4, cpu: "avr", os: "bare" };

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

test "sizeof refuses an extern class placeholder that never resolved" {
	const result = compileToC("extern class OpaqueThing;\nconst w: int32 = sizeof(OpaqueThing);\nconsole.log(w);");
	assert !result.ok;
	assert result.error.contains("'sizeof' needs a type with a known layout");
}

test "sizeof defers a struct to the C compiler on a 16-bit target" {
	const result = compileToC("struct Head { c: int8; x: int64 }\nconst w: int32 = sizeof(Head);\nconsole.log(w);", avr);
	assert result.ok;
	assert result.value.contains("sizeof(Head");
	assert !result.value.contains("= (int32_t)16;");
}

test "sizeof refuses void rather than folding it to zero" {
	const result = compileToC("const w: int32 = sizeof(void);\nconsole.log(w);");
	assert !result.ok;
	assert result.error.contains("'sizeof' needs a type with a known layout");
}
