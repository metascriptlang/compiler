// Integer conversion materialization on the JS backend — docs/JS-NUMERIC.md.
//
// A JS number carries its fraction through every slot that C would have
// truncated, so a conversion the checker parked on a HiddenStdConv has to be
// spelled out by the backend or `const x: int32 = 3.9` keeps the .9. C spells
// the same two nodes as msCheckRangeI32(...); these pin the JS spelling.
//
// Runtime coverage for the values themselves: corpus/programs/016-jsIntegerModel.ms.

import { compileToJS } from "../helpers";

test "explicit int32 cast truncates" {
	const result = compileToJS("const f = 3.9; const a = f as int32;");
	assert result.ok;
	assert result.value.contains("| 0");
}

test "declared int32 slot truncates without an explicit cast" {
	const result = compileToJS("const f = 3.9; const a: int32 = f;");
	assert result.ok;
	assert result.value.contains("| 0");
}

test "uint8 conversion masks to a byte" {
	const result = compileToJS("const f = 3.9; const a = f as uint8;");
	assert result.ok;
	assert result.value.contains("& 255");
}

test "uint16 conversion masks to a half word" {
	const result = compileToJS("const f = 3.9; const a = f as uint16;");
	assert result.ok;
	assert result.value.contains("& 65535");
}

test "uint32 conversion shifts unsigned" {
	const result = compileToJS("const f = 3.9; const a = f as uint32;");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "int64 conversion truncates through the global Math" {
	const result = compileToJS("const f = 3.9; const a = f as int64;");
	assert result.ok;
	assert result.value.contains("Math.trunc");
}

// The prelude declares its own `class Math`, and the JS naming oracle mangles a
// module global. The receiver this pass synthesizes has to stay unbound so it
// reaches the engine's Math — hence the pass trailing resolveRuntimeIdents.
test "synthesized Math receiver is not mangled to the prelude class" {
	const result = compileToJS("const f = 3.9; const a = f as int64;");
	assert result.ok;
	assert !result.value.contains("_Math");
}

test "float slot is left alone" {
	const result = compileToJS("const f = 3.9; const a: float64 = f;");
	assert result.ok;
	assert !result.value.contains("| 0");
}

test "string cast is left alone" {
	const result = compileToJS("const s = \"x\"; const a = s as string;");
	assert result.ok;
	assert !result.value.contains("| 0");
}
